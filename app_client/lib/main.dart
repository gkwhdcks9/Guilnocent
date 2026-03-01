import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';

const String kDefaultServerWsUrl = String.fromEnvironment(
  'SERVER_WS_URL',
  defaultValue: 'ws://127.0.0.1:8080',
);

void main() {
  runApp(const MafiaDailyApp());
}

class MafiaDailyApp extends StatelessWidget {
  const MafiaDailyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily Mafia',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F14),
        cardTheme: CardThemeData(
          color: const Color(0xFF191A22),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0x33FFFFFF)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF11131B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const GameHomePage(),
    );
  }
}

class GameHomePage extends StatefulWidget {
  const GameHomePage({super.key});

  @override
  State<GameHomePage> createState() => _GameHomePageState();
}

class _GameHomePageState extends State<GameHomePage> {
  final _serverController = TextEditingController(text: kDefaultServerWsUrl);
  final _nameController = TextEditingController(text: '플레이어');
  final _roomController = TextEditingController();
  final _roomSearchController = TextEditingController();
  final _chatController = TextEditingController();
  final _misleadController = TextEditingController();

  IOWebSocketChannel? _channel;
  Timer? _connectTimeout;
  String? _myPlayerId;
  String _myRole = 'unknown';
  RoomState? _room;
  final List<LobbyRoomInfo> _availableRooms = [];
  final List<ChatItem> _chatLogs = [];
  final List<String> _privateLogs = [];
  String _status = '서버 연결 전';
  bool _moveToChatOnEnter = false;
  int _roomTab = 0;
  bool _waitingOnly = true;

  bool get _connected => _channel != null;
  bool get _inRoom => _room != null;
  bool get _isHost => _inRoom && _room!.hostId == _myPlayerId;
  bool get _isMafia => _myRole == 'mafia';

  @override
  void dispose() {
    _serverController.dispose();
    _nameController.dispose();
    _roomController.dispose();
    _roomSearchController.dispose();
    _chatController.dispose();
    _misleadController.dispose();
    _connectTimeout?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  void _connect() {
    final server = _serverController.text.trim();
    if (server.isEmpty) return;

    _connectTimeout?.cancel();
    _channel?.sink.close();

    try {
      final channel = IOWebSocketChannel.connect(server);
      setState(() {
        _channel = channel;
        _status = '연결 시도 중...';
        _myPlayerId = null;
        _myRole = 'unknown';
        _room = null;
        _availableRooms.clear();
        _chatLogs.clear();
        _privateLogs.clear();
        _roomTab = 0;
        _moveToChatOnEnter = false;
      });

      _connectTimeout = Timer(const Duration(seconds: 8), () {
        if (!mounted) return;
        if (_channel == channel && _myPlayerId == null) {
          setState(() {
            _status = '연결 시간초과: 주소/서버/방화벽을 확인하세요';
            _channel = null;
          });
          channel.sink.close();
        }
      });

      channel.stream.listen(
        _onMessage,
        onError: (error) {
          _connectTimeout?.cancel();
          setState(() {
            _status = '연결 오류: $error';
            _channel = null;
          });
        },
        onDone: () {
          _connectTimeout?.cancel();
          setState(() {
            if (_myPlayerId == null) {
              _status = '연결 실패 또는 종료';
            } else {
              _status = '연결 종료';
            }
            _channel = null;
            _room = null;
          });
        },
      );
    } catch (error) {
      _connectTimeout?.cancel();
      setState(() {
        _status = '연결 실패: $error';
      });
    }
  }

  void _send(Map<String, dynamic> data) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(data));
  }

  void _onMessage(dynamic raw) {
    final packet = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = packet['type'] as String? ?? '';

    if (type == 'welcome') {
      _connectTimeout?.cancel();
      setState(() {
        _myPlayerId = packet['playerId'] as String?;
        _status = '연결됨';
      });
      _send({
        'type': 'set_name',
        'name': _nameController.text.trim(),
      });
      _requestRooms();
      return;
    }

    if (type == 'name_set') {
      setState(() {
        _status = '이름 설정 완료';
      });
      return;
    }

    if (type == 'error') {
      setState(() {
        _status = packet['message'] as String? ?? '오류';
      });
      return;
    }

    if (type == 'room_update') {
      final wasInRoom = _room != null;
      final room = RoomState.fromJson(packet['room'] as Map<String, dynamic>);
      setState(() {
        _room = room;
        _status = '방 상태 갱신';
        if (!wasInRoom) {
          _roomTab = _moveToChatOnEnter ? 1 : 0;
        }
        _moveToChatOnEnter = false;
      });
      return;
    }

    if (type == 'rooms_list') {
      final list = (packet['rooms'] as List<dynamic>? ?? [])
          .map((item) => LobbyRoomInfo.fromJson(item as Map<String, dynamic>))
          .toList();
      setState(() {
        _availableRooms
          ..clear()
          ..addAll(list);
      });
      return;
    }

    if (type == 'chat') {
      final chat = ChatItem.fromJson(packet['chat'] as Map<String, dynamic>);
      setState(() {
        _chatLogs.add(chat);
      });
      return;
    }

    if (type == 'private_info') {
      final message = packet['message'] as String? ?? '';
      setState(() {
        _privateLogs.add(message);
      });
      return;
    }

    if (type == 'role_assigned') {
      final role = packet['role'] as String? ?? 'unknown';
      final day = packet['day'] as int? ?? 0;
      setState(() {
        _myRole = role;
        _privateLogs.add('$day일차 내 역할: ${role == 'mafia' ? '마피아' : '시민'}');
      });
      return;
    }

    if (type == 'left_room') {
      setState(() {
        _room = null;
        _roomTab = 0;
      });
      _requestRooms();
      return;
    }
  }

  void _createRoom() {
    _moveToChatOnEnter = true;
    _send({
      'type': 'create_room',
      'roomId': _roomController.text.trim(),
    });
  }

  void _createAutoRoom() {
    _moveToChatOnEnter = true;
    _send({'type': 'create_room'});
  }

  void _joinRoom() {
    _send({
      'type': 'join_room',
      'roomId': _roomController.text.trim(),
    });
  }

  void _joinRoomById(String roomId) {
    _roomController.text = roomId;
    _joinRoom();
  }

  void _requestRooms() {
    _send({'type': 'list_rooms'});
  }

  void _sendChat() {
    final message = _chatController.text.trim();
    if (message.isEmpty) return;
    _send({'type': 'send_chat', 'message': message});
    _chatController.clear();
  }

  void _castVote(String? targetId) {
    _send({'type': 'set_vote', 'targetId': targetId});
  }

  void _useCitizenInspect(String targetId) {
    _send({'type': 'use_ability', 'ability': 'inspect', 'targetId': targetId});
  }

  void _useMafiaMislead() {
    final text = _misleadController.text.trim();
    if (text.isEmpty) return;
    _send({'type': 'use_ability', 'ability': 'mislead', 'text': text});
    _misleadController.clear();
  }

  String _formatTime(int? epochMs) {
    if (epochMs == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _phaseLabel(String phase) {
    switch (phase) {
      case 'lobby':
        return '대기';
      case 'morning':
        return '아침';
      case 'voting':
        return '처형 투표';
      case 'ended':
        return '종료';
      default:
        return phase;
    }
  }

  String _roleLabel(String role) {
    if (role == 'mafia') return '마피아';
    if (role == 'citizen') return '시민';
    return '미정';
  }

  Widget _sectionTitle(BuildContext context, String title, {IconData? icon}) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
        ],
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }

  Widget _panel({required Widget child}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final players = room?.players ?? const <PlayerInfo>[];
    final canShowGameControls = room != null;
    final roleColor = _myRole == 'mafia'
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.tertiary;
    final myName = _nameController.text.trim();
    final search = _roomSearchController.text.trim().toLowerCase();
    final filteredRooms = _availableRooms.where((roomInfo) {
      if (_waitingOnly && roomInfo.inProgress) return false;
      if (search.isEmpty) return true;
      return roomInfo.id.toLowerCase().contains(search) ||
        roomInfo.hostName.toLowerCase().contains(search);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('DAILY MAFIA'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Chip(
                label: Text(_connected ? 'ONLINE' : 'OFFLINE'),
                avatar: Icon(
                  _connected ? Icons.wifi : Icons.wifi_off,
                  size: 16,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF121218), Color(0xFF0A0B10)],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (!_inRoom) ...[
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '접속 설정', icon: Icons.sensors),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _serverController,
                      decoration: const InputDecoration(labelText: 'WebSocket 주소 (ws://IP:8080)'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(labelText: '닉네임'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _connect,
                            icon: const Icon(Icons.wifi_find),
                            label: const Text('서버 연결'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '상태: $_status',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '입장 허브', icon: Icons.vpn_key),
                    const SizedBox(height: 8),
                    Text(
                      '코드를 입력해 입장하거나, 자동 코드로 빠르게 방을 만들 수 있습니다.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _roomController,
                      decoration: const InputDecoration(labelText: '방 코드 입력'),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _connected ? _joinRoom : null,
                            child: const Text('코드로 입장'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _connected ? _createRoom : null,
                            child: const Text('코드로 생성'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _connected ? _createAutoRoom : null,
                        icon: const Icon(Icons.flash_on),
                        label: const Text('빠른 방 만들기 (자동 코드)'),
                      ),
                    ),
                  ],
                ),
              ),
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: _sectionTitle(context, '공개 로비 목록', icon: Icons.list_alt)),
                        IconButton(
                          onPressed: _connected ? _requestRooms : null,
                          icon: const Icon(Icons.refresh),
                          tooltip: '목록 새로고침',
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _roomSearchController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '방 코드/호스트 검색',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _waitingOnly,
                      onChanged: (value) {
                        setState(() {
                          _waitingOnly = value;
                        });
                      },
                      title: const Text('대기방만 보기'),
                    ),
                    if (filteredRooms.isEmpty)
                      Text(
                        _connected
                            ? (_availableRooms.isEmpty ? '생성된 방이 없습니다. 먼저 방을 만들어보세요.' : '조건에 맞는 방이 없습니다.')
                            : '먼저 서버에 연결하세요.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    for (final roomInfo in filteredRooms)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: const Color(0x331B1D25),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('ROOM ${roomInfo.id}'),
                                  const SizedBox(height: 2),
                                  Text(
                                    '호스트 ${roomInfo.hostName} · ${roomInfo.playerCount}명 · ${_phaseLabel(roomInfo.phase)}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: roomInfo.inProgress ? null : () => _joinRoomById(roomInfo.id),
                              child: Text(roomInfo.inProgress ? '진행중' : '입장'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (_inRoom)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '로비', icon: Icons.castle),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF232531), Color(0xFF161821)],
                        ),
                        border: Border.all(color: const Color(0x44FFFFFF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ROOM ${room!.id}', style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(
                                avatar: const Icon(Icons.schedule, size: 16),
                                label: Text('DAY ${room.game.day} · ${_phaseLabel(room.game.phase)}'),
                              ),
                              Chip(
                                avatar: Icon(Icons.person, size: 16, color: roleColor),
                                label: Text('내 역할 ${_roleLabel(_myRole)}'),
                              ),
                              Chip(
                                avatar: const Icon(Icons.group, size: 16),
                                label: Text('인원 ${players.length}명'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '호스트: ${room.hostId == _myPlayerId ? myName : room.hostId}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              OutlinedButton(
                                onPressed: _connected && _inRoom ? () => _send({'type': 'leave_room'}) : null,
                                child: const Text('로비 나가기'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (_inRoom)
              _panel(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment<int>(value: 0, icon: Icon(Icons.castle), label: Text('로비')), 
                    ButtonSegment<int>(value: 1, icon: Icon(Icons.forum), label: Text('채팅')), 
                  ],
                  selected: {_roomTab},
                  onSelectionChanged: (values) {
                    setState(() {
                      _roomTab = values.first;
                    });
                  },
                ),
              ),
            if (canShowGameControls && _roomTab == 0)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '진행 제어', icon: Icons.settings),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton(
                          onPressed: _isHost && room.game.canStart ? () => _send({'type': 'start_game'}) : null,
                          child: const Text('게임 시작'),
                        ),
                        ElevatedButton(
                          onPressed: _isHost && room.game.inProgress && room.game.phase == 'morning'
                              ? () => _send({'type': 'start_voting'})
                              : null,
                          child: const Text('투표 시작'),
                        ),
                        ElevatedButton(
                          onPressed: _isHost && room.game.inProgress && room.game.phase == 'voting'
                              ? () => _send({'type': 'close_voting'})
                              : null,
                          child: const Text('투표 마감'),
                        ),
                      ],
                    ),
                    if (room.game.inProgress && room.game.phase == 'voting' && _isMafia) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: () => _send({'type': 'mafia_continue', 'continueGame': true}),
                            child: const Text('마피아: 다음날 진행'),
                          ),
                          OutlinedButton(
                            onPressed: () => _send({'type': 'mafia_continue', 'continueGame': false}),
                            child: const Text('마피아: 종료 선택'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            if (room != null && _roomTab == 0)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '플레이어', icon: Icons.groups),
                    const SizedBox(height: 8),
                    for (final player in players)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: const Color(0x331B1D25),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${player.name} ${player.id == _myPlayerId ? '(나)' : ''}'),
                                  Text(
                                    '점수 ${player.score}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            if (room.game.inProgress && room.game.phase == 'voting')
                              FilledButton.tonalIcon(
                                onPressed: () => _castVote(player.id),
                                icon: const Icon(Icons.how_to_vote),
                                label: const Text('투표'),
                              ),
                          ],
                        ),
                      ),
                    if (room.game.inProgress && room.game.phase == 'voting')
                      OutlinedButton.icon(
                        onPressed: () => _castVote(null),
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text('기권'),
                      ),
                  ],
                ),
              ),
            if (room != null && room.game.inProgress && room.game.phase == 'morning' && _roomTab == 0)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '능력 사용', icon: Icons.auto_awesome),
                    const SizedBox(height: 8),
                    if (_myRole == 'citizen')
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: players
                            .where((p) => p.id != _myPlayerId)
                            .map(
                              (p) => OutlinedButton.icon(
                                onPressed: () => _useCitizenInspect(p.id),
                                icon: const Icon(Icons.search),
                                label: Text('${p.name} 조사'),
                              ),
                            )
                            .toList(),
                      ),
                    if (_myRole == 'mafia') ...[
                      TextField(
                        controller: _misleadController,
                        decoration: const InputDecoration(labelText: '익명 제보 텍스트'),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _useMafiaMislead,
                        icon: const Icon(Icons.campaign),
                        label: const Text('익명 제보 사용'),
                      ),
                    ],
                  ],
                ),
              ),
            if (_inRoom && _roomTab == 1)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '채팅방', icon: Icons.forum),
                    const SizedBox(height: 8),
                    Container(
                      height: 260,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF12141C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: ListView.builder(
                        itemCount: _chatLogs.length,
                        itemBuilder: (context, index) {
                          final item = _chatLogs[index];
                          final isMine = item.fromId != null && item.fromId == _myPlayerId;
                          final bubbleColor = item.system
                              ? Theme.of(context).colorScheme.surfaceContainerHighest
                              : isMine
                                  ? const Color(0xFF40315A)
                                  : const Color(0xFF232736);

                          return Align(
                            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 300),
                              margin: const EdgeInsets.only(bottom: 7),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: bubbleColor,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.system ? 'SYSTEM' : item.fromName,
                                    style: Theme.of(context).textTheme.labelSmall,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(item.message),
                                  if (item.ts != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      _formatTime(item.ts),
                                      style: Theme.of(context).textTheme.labelSmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            decoration: const InputDecoration(labelText: '메시지'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _sendChat,
                          icon: const Icon(Icons.send),
                          label: const Text('전송'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (_privateLogs.isNotEmpty && _inRoom)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '개인 로그', icon: Icons.lock),
                    const SizedBox(height: 8),
                    for (final item in _privateLogs.reversed.take(8))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $item'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class RoomState {
  RoomState({
    required this.id,
    required this.hostId,
    required this.players,
    required this.game,
  });

  final String id;
  final String hostId;
  final List<PlayerInfo> players;
  final GameState game;

  factory RoomState.fromJson(Map<String, dynamic> json) {
    final playersJson = (json['players'] as List<dynamic>? ?? []);
    return RoomState(
      id: json['id'] as String? ?? '',
      hostId: json['hostId'] as String? ?? '',
      players: playersJson
          .map((item) => PlayerInfo.fromJson(item as Map<String, dynamic>))
          .toList(),
      game: GameState.fromJson(json['game'] as Map<String, dynamic>? ?? {}),
    );
  }
}

class PlayerInfo {
  PlayerInfo({required this.id, required this.name, required this.score});

  final String id;
  final String name;
  final int score;

  factory PlayerInfo.fromJson(Map<String, dynamic> json) {
    return PlayerInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'unknown',
      score: json['score'] as int? ?? 0,
    );
  }
}

class GameState {
  GameState({
    required this.inProgress,
    required this.day,
    required this.phase,
    required this.canStart,
  });

  final bool inProgress;
  final int day;
  final String phase;
  final bool canStart;

  factory GameState.fromJson(Map<String, dynamic> json) {
    return GameState(
      inProgress: json['inProgress'] as bool? ?? false,
      day: json['day'] as int? ?? 0,
      phase: json['phase'] as String? ?? 'lobby',
      canStart: json['canStart'] as bool? ?? false,
    );
  }
}

class ChatItem {
  ChatItem({
    this.fromId,
    required this.fromName,
    required this.message,
    required this.system,
    this.ts,
  });

  final String? fromId;
  final String fromName;
  final String message;
  final bool system;
  final int? ts;

  factory ChatItem.fromJson(Map<String, dynamic> json) {
    return ChatItem(
      fromId: json['fromId'] as String?,
      fromName: json['fromName'] as String? ?? 'unknown',
      message: json['message'] as String? ?? '',
      system: json['system'] as bool? ?? false,
      ts: json['ts'] as int?,
    );
  }
}

class LobbyRoomInfo {
  LobbyRoomInfo({
    required this.id,
    required this.hostName,
    required this.playerCount,
    required this.inProgress,
    required this.phase,
  });

  final String id;
  final String hostName;
  final int playerCount;
  final bool inProgress;
  final String phase;

  factory LobbyRoomInfo.fromJson(Map<String, dynamic> json) {
    return LobbyRoomInfo(
      id: json['id'] as String? ?? '',
      hostName: json['hostName'] as String? ?? 'unknown',
      playerCount: json['playerCount'] as int? ?? 0,
      inProgress: json['inProgress'] as bool? ?? false,
      phase: json['phase'] as String? ?? 'lobby',
    );
  }
}
