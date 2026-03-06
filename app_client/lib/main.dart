import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';

const String kPublicServerWsUrl = 'wss://daily-mafia-server.onrender.com';
const String kDefaultLanServerWsUrl = 'ws://127.0.0.1:8080';
const int kLanDiscoveryPort = 41234;
const String kLanDiscoveryMagic = 'GUILNOCENT_DISCOVER';
const String kRequiredRulesVersion = '2026.03.06-rules-1';
const String kDangerLogPrefix = '[!DANGER!] ';
const List<String> kQuickEmojis = ['😀', '😂', '😱', '🤔', '😡', '😭'];

void main() {
  runApp(const MafiaDailyApp());
}

class MafiaDailyApp extends StatelessWidget {
  const MafiaDailyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'guilnocent',
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
  final _chatScrollController = ScrollController();
  final _lanServerController = TextEditingController(text: kDefaultLanServerWsUrl);
  final _nameController = TextEditingController(text: '플레이어');
  final _roomController = TextEditingController();
  final _roomSearchController = TextEditingController();
  final _chatController = TextEditingController();

  IOWebSocketChannel? _channel;
  Timer? _connectTimeout;
  Timer? _phaseTicker;
  String? _myPlayerId;
  String _myRole = 'unknown';
  String? _jokerFakeRole;
  final Set<String> _mafiaTeammateIds = <String>{};
  RoomState? _room;
  final List<LobbyRoomInfo> _availableRooms = [];
  final List<ChatItem> _chatLogs = [];
  final List<String> _privateLogs = [];
  String? _serverEndpoint;
  String _status = '서버 연결 전';
  bool _isConnecting = false;
  bool _isDiscoveringLan = false;
  bool _isDisposing = false;
  bool _waitingOnly = true;
  bool _chatNearBottom = true;
  int _unreadChatCount = 0;
  String _settingsTab = 'game';
  static const double _unifiedModalWidthFactor = 0.9;
  static const double _unifiedModalHeightFactor = 0.62;
  final Set<String> _sessionResetRoomIds = <String>{};
  final Set<int> _loggedRoleDescriptionDays = <int>{};
  VoidCallback? _refreshSettingsModal;
  VoidCallback? _refreshPlayersModal;
  VoidCallback? _refreshActionModal;

  bool get _connected => _channel != null;
  bool get _inRoom => _room != null;
  bool get _isHost => _inRoom && _room!.hostId == _myPlayerId;
  bool get _isMyEliminated {
    final room = _room;
    final myPlayerId = _myPlayerId;
    if (room == null || myPlayerId == null) return false;
    return room.game.eliminatedIds.contains(myPlayerId);
  }

  @override
  void initState() {
    super.initState();
    _chatScrollController.addListener(_onChatScroll);
    _phaseTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _isDisposing) return;
      if (_room?.game.phaseEndsAt == null) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _isDisposing = true;
    _lanServerController.dispose();
    _nameController.dispose();
    _roomController.dispose();
    _roomSearchController.dispose();
    _chatController.dispose();
    _chatScrollController.removeListener(_onChatScroll);
    _chatScrollController.dispose();
    _phaseTicker?.cancel();
    _connectTimeout?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  void _connect() {
    final server = _serverEndpoint;
    if (server == null || server.isEmpty) {
      setState(() {
        _status = '서버를 먼저 선택하세요';
      });
      return;
    }

    _connectTimeout?.cancel();
    _channel?.sink.close();

    try {
      final channel = IOWebSocketChannel.connect(server);
      setState(() {
        _isConnecting = true;
        _channel = channel;
        _status = '연결 시도 중...';
        _myPlayerId = null;
        _myRole = 'unknown';
        _jokerFakeRole = null;
        _mafiaTeammateIds.clear();
        _room = null;
        _availableRooms.clear();
        _chatLogs.clear();
        _privateLogs.clear();
      });

      _connectTimeout = Timer(const Duration(seconds: 25), () {
        if (!mounted || _isDisposing) return;
        if (_channel == channel && _myPlayerId == null) {
          setState(() {
            _isConnecting = false;
            _status = '연결 시간초과: 서버가 슬립 상태일 수 있습니다. 잠시 후 다시 시도하세요';
            _channel = null;
          });
          channel.sink.close();
        }
      });

      channel.stream.listen(
        _onMessage,
        onError: (error) {
          _connectTimeout?.cancel();
          if (!mounted || _isDisposing) return;
          setState(() {
            _isConnecting = false;
            _status = '연결 오류: $error';
            _channel = null;
            _myPlayerId = null;
            _myRole = 'unknown';
            _jokerFakeRole = null;
            _mafiaTeammateIds.clear();
          });
        },
        onDone: () {
          _connectTimeout?.cancel();
          if (!mounted || _isDisposing) return;
          setState(() {
            _isConnecting = false;
            if (_myPlayerId == null) {
              _status = '연결 실패 또는 종료';
            } else {
              _status = '연결 종료';
            }
            _channel = null;
            _myPlayerId = null;
            _room = null;
            _myRole = 'unknown';
            _jokerFakeRole = null;
            _mafiaTeammateIds.clear();
          });
        },
      );
    } catch (error) {
      _connectTimeout?.cancel();
      setState(() {
        _isConnecting = false;
        _status = '연결 실패: $error';
      });
    }
  }

  void _selectPublicServer() {
    setState(() {
      _serverEndpoint = kPublicServerWsUrl;
      _status = '공용 서버 선택됨';
    });
    _connect();
  }

  void _selectLanServer() {
    final lan = _lanServerController.text.trim();
    if (lan.isEmpty) {
      setState(() {
        _status = 'LAN 서버 주소를 입력하세요';
      });
      return;
    }
    setState(() {
      _serverEndpoint = lan;
      _status = 'LAN 서버 선택됨';
    });
    _connect();
  }

  Future<void> _discoverAndSelectLanServer() async {
    if (_isDiscoveringLan) return;
    setState(() {
      _isDiscoveringLan = true;
      _status = 'LAN 서버 탐색 중...';
    });

    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final completer = Completer<String?>();
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read || completer.isCompleted) return;
        final datagram = socket?.receive();
        if (datagram == null) return;

        final text = utf8.decode(datagram.data);
        try {
          final payload = jsonDecode(text) as Map<String, dynamic>;
          if ((payload['magic'] as String?) != 'GUILNOCENT_SERVER') return;
          final wsUrl = payload['wsUrl'] as String?;
          if (wsUrl != null && wsUrl.isNotEmpty) {
            completer.complete(wsUrl);
            return;
          }
          final port = payload['port'] as int? ?? 8080;
          completer.complete('ws://${datagram.address.address}:$port');
        } catch (_) {
          return;
        }
      });

      socket.send(
        utf8.encode(kLanDiscoveryMagic),
        InternetAddress('255.255.255.255'),
        kLanDiscoveryPort,
      );

      final endpoint = await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => null,
      );

      if (!mounted || _isDisposing) return;

      if (endpoint == null) {
        setState(() {
          _status = 'LAN 서버를 찾지 못했습니다. 주소를 직접 입력해 연결하세요.';
        });
        return;
      }

      _lanServerController.text = endpoint;
      setState(() {
        _serverEndpoint = endpoint;
        _status = 'LAN 서버 발견: $endpoint';
      });
      _connect();
    } catch (error) {
      if (!mounted || _isDisposing) return;
      setState(() {
        _status = 'LAN 탐색 오류: $error';
      });
    } finally {
      await subscription?.cancel();
      socket?.close();
      if (mounted && !_isDisposing) {
        setState(() {
          _isDiscoveringLan = false;
        });
      }
    }
  }

  void _send(Map<String, dynamic> data) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(data));
  }

  void _scrollChatToBottom({bool animated = true}) {
    if (!_chatScrollController.hasClients) return;
    final position = _chatScrollController.position.maxScrollExtent;
    if (animated) {
      _chatScrollController.animateTo(
        position,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    _chatScrollController.jumpTo(position);
  }

  bool _isChatNearBottomNow() {
    if (!_chatScrollController.hasClients) return true;
    final remain = _chatScrollController.position.maxScrollExtent - _chatScrollController.position.pixels;
    return remain <= 40;
  }

  void _onChatScroll() {
    if (!mounted || _isDisposing) return;
    final nearBottom = _isChatNearBottomNow();
    if (nearBottom == _chatNearBottom && !(nearBottom && _unreadChatCount > 0)) {
      return;
    }
    setState(() {
      _chatNearBottom = nearBottom;
      if (nearBottom) {
        _unreadChatCount = 0;
      }
    });
  }

  void _jumpToLatestChat() {
    _scrollChatToBottom();
    if (!mounted || _isDisposing) return;
    setState(() {
      _chatNearBottom = true;
      _unreadChatCount = 0;
    });
  }

  void _appendRoleDescriptionForDay(int day, String role, {String? fakeRole}) {
    if (day <= 0) return;
    if (_loggedRoleDescriptionDays.contains(day)) return;
    _loggedRoleDescriptionDays.add(day);
    final roleDescription = _roleDescription(role, fakeRole: fakeRole);
    _privateLogs.add('[$day일차] $roleDescription');
  }

  void _onMessage(dynamic raw) {
    if (!mounted || _isDisposing) return;
    final packet = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = packet['type'] as String? ?? '';

    if (type == 'welcome') {
      final serverRulesVersion = (packet['rulesVersion'] as String?)?.trim() ?? '';
      final versionMismatch = serverRulesVersion != kRequiredRulesVersion;

      _connectTimeout?.cancel();
      setState(() {
        _isConnecting = false;
        _myPlayerId = packet['playerId'] as String?;
        _status = versionMismatch
            ? '연결됨 (버전 불일치: 서버 $serverRulesVersion / 앱 $kRequiredRulesVersion)'
            : '연결됨 (규칙 버전 $serverRulesVersion)';
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(versionMismatch
                ? 'CONNECTED (서버 버전이 최신과 다를 수 있음: $serverRulesVersion)'
                : 'CONNECTED'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
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
      final room = RoomState.fromJson(packet['room'] as Map<String, dynamic>);
      final previous = _room;
      final restartedFromEnded =
          previous != null &&
          previous.game.phase == 'ended' &&
          room.game.inProgress &&
          room.game.day == 1;
      setState(() {
        _room = room;
        _status = '방 상태 갱신';
        if (restartedFromEnded) {
          _privateLogs.clear();
          _loggedRoleDescriptionDays.clear();
        }
        if (room.game.inProgress && room.game.day > 0 && _myRole != 'unknown') {
          _appendRoleDescriptionForDay(room.game.day, _myRole, fakeRole: _jokerFakeRole);
        }
      });
      _refreshSettingsModal?.call();
      _refreshPlayersModal?.call();
      _refreshActionModal?.call();
      _resetRoomSettingsForSessionIfNeeded(room);
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
        _chatNearBottom = true;
        _unreadChatCount = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDisposing) return;
        _scrollChatToBottom();
      });
      return;
    }

    if (type == 'ability_log') {
      final message = packet['message'] as String? ?? '';
      final day = packet['day'] as int? ?? _room?.game.day ?? 0;
      setState(() {
        if (day > 0) {
          _privateLogs.add('[$day일차] $message');
        } else {
          _privateLogs.add(message);
        }
      });
      return;
    }

    if (type == 'role_assigned') {
      final role = packet['role'] as String? ?? 'unknown';
      final fakeRole = packet['fakeRole'] as String?;
      final day = packet['day'] as int? ?? 0;
      final mafiaPeerIds = (packet['mafiaPeerIds'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toSet();
      setState(() {
        if (day == 1) {
          _privateLogs.clear();
          _loggedRoleDescriptionDays.clear();
        }
        _myRole = role;
        _jokerFakeRole = role == 'joker' ? fakeRole : null;
        _mafiaTeammateIds
          ..clear()
          ..addAll(role == 'mafia' ? mafiaPeerIds : const <String>{});
        _appendRoleDescriptionForDay(day, role, fakeRole: fakeRole);
        if (role == 'joker' && fakeRole != null && fakeRole.isNotEmpty) {
          _status = '${_roleLabel(fakeRole)} 배정';
        }
      });
      return;
    }

    if (type == 'left_room') {
      setState(() {
        _room = null;
        _myRole = 'unknown';
        _jokerFakeRole = null;
        _mafiaTeammateIds.clear();
        _chatLogs.clear();
        _privateLogs.clear();
        _loggedRoleDescriptionDays.clear();
        _unreadChatCount = 0;
        _chatNearBottom = true;
        _status = '방에서 나왔습니다. 기록이 초기화되었습니다.';
      });
      _requestRooms();
      return;
    }
  }

  void _createRoom() {
    _send({
      'type': 'create_room',
      'roomId': _roomController.text.trim(),
    });
  }

  void _createAutoRoom() {
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

  void _sendEmoji(String emoji) {
    _send({'type': 'send_emoji', 'emoji': emoji});
  }

  void _applyNickname() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    _send({'type': 'set_name', 'name': name});
    setState(() {
      _status = '닉네임 변경 요청 중...';
    });
  }

  void _castVote(String? targetId) {
    _send({'type': 'set_vote', 'targetId': targetId});
  }

  void _castExecutionVote(bool approve) {
    _send({'type': 'set_execution_vote', 'approve': approve});
  }

  void _setMafiaContinue(bool shouldContinue) {
    _send({
      'type': 'mafia_continue',
      'decision': shouldContinue ? 'continue' : 'stop',
    });
  }

  void _setGameMode(String mode) {
    _send({'type': 'set_game_mode', 'mode': mode});
  }

  void _setScoreSettings({
    int? mafiaJoker2Plus,
    int? mafiaJoker1,
    int? mafiaJoker0,
    int? citizenEndMultiplier,
  }) {
    final room = _room;
    if (room == null) return;
    final next = Map<String, int>.from(room.game.scoreSettings);
    if (mafiaJoker2Plus != null) {
      next['mafiaJoker2Plus'] = mafiaJoker2Plus;
    }
    if (mafiaJoker1 != null) {
      next['mafiaJoker1'] = mafiaJoker1;
    }
    if (mafiaJoker0 != null) {
      next['mafiaJoker0'] = mafiaJoker0;
    }
    if (citizenEndMultiplier != null) {
      next['citizenEndMultiplier'] = citizenEndMultiplier;
    }
    _send({'type': 'set_score_settings', 'scoreSettings': next});
  }

  void _resetRoomSettingsForSessionIfNeeded(RoomState room) {
    final myPlayerId = _myPlayerId;
    if (myPlayerId == null) return;
    if (room.hostId != myPlayerId) return;
    if (room.game.inProgress) return;
    if (_sessionResetRoomIds.contains(room.id)) return;
    _sessionResetRoomIds.add(room.id);
    _setGameMode('moral_roulette');
  }

  void _adjustRoleCount(String roleKey, int delta) {
    final room = _room;
    if (room == null) return;
    if (room.game.inProgress) return;
    if (room.game.mode == 'moral_roulette' && roleKey != 'joker') return;
    final current = room.game.roleCounts[roleKey] ?? 0;
    final next = (current + delta).clamp(0, 12);
    if (roleKey == 'mafia' && next < 1) return;

    final updated = Map<String, int>.from(room.game.roleCounts);
    updated[roleKey] = next;
    _send({'type': 'set_role_counts', 'roleCounts': updated});
  }

  void _onPlayerSelect(String playerId) {
    final room = _room;
    if (room == null) return;

    final isSelfTarget = playerId == _myPlayerId;
    final canSelfTargetInAbility = room.game.phase == 'ability' &&
        (_myRole == 'doctor' || (_myRole == 'joker' && _jokerFakeRole == 'doctor'));
    if (isSelfTarget && !canSelfTargetInAbility) {
      return;
    }

    if (_isMyEliminated) {
      setState(() {
        _status = '탈락 상태에서는 능력/투표를 할 수 없습니다.';
      });
      return;
    }
    if (room.game.eliminatedIds.contains(playerId)) {
      setState(() {
        _status = '탈락한 플레이어는 선택할 수 없습니다.';
      });
      return;
    }

    if (room.game.phase == 'ability') {
      if (_myRole == 'citizen') {
        setState(() {
          _status = '시민은 대상 역할을 확인할 수 없습니다.';
        });
        return;
      }
      if (_myRole == 'mafia') {
        _send({'type': 'use_ability', 'ability': 'eliminate', 'targetId': playerId});
        return;
      }
      if (_myRole == 'doctor') {
        _send({'type': 'use_ability', 'ability': 'heal', 'targetId': playerId});
        return;
      }
      if (_myRole == 'police') {
        _send({'type': 'use_ability', 'ability': 'inspect', 'targetId': playerId});
        return;
      }
      if (_myRole == 'joker') {
        _send({'type': 'use_ability', 'ability': 'joker_act', 'targetId': playerId});
        return;
      }
      setState(() {
        _status = '이번 턴에는 사용할 능력이 없습니다.';
      });
      return;
    }

    if (room.game.phase == 'voting') {
      _castVote(playerId);
      return;
    }

    setState(() {
      _status = '현재는 대상 선택 단계가 아닙니다.';
    });
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
      case 'ability':
        return '밤 능력';
      case 'voting':
        return '처형 투표';
      case 'execution_vote':
        return '처형 찬반';
      case 'mafia_decision':
        return '마피아 진행 선택';
      case 'ended':
        return '종료';
      default:
        return phase;
    }
  }

  String _modeLabel(String mode) {
    if (mode == 'original') return '오리지널 마피아';
    if (mode == 'moral_roulette') return 'Moral Roulette';
    return mode;
  }

  int _remainSeconds(GameState game) {
    final endsAt = game.phaseEndsAt;
    if (endsAt == null) return 0;
    final remainMs = endsAt - DateTime.now().millisecondsSinceEpoch;
    if (remainMs <= 0) return 0;
    return (remainMs / 1000).ceil();
  }

  double _phaseProgress(GameState game) {
    final total = game.phaseDurationSec;
    if (total == null || total <= 0) return 0;
    final remain = _remainSeconds(game);
    return (remain / total).clamp(0, 1).toDouble();
  }

  String _roleLabel(String role) {
    if (role == 'mafia') return '마피아';
    if (role == 'police') return '경찰';
    if (role == 'citizen') return '시민';
    if (role == 'doctor') return '의사';
    if (role == 'joker') return '조커';
    return '미정';
  }

  String _displayRoleLabelInGame() {
    if (_myRole == 'joker' && _jokerFakeRole != null && _jokerFakeRole!.isNotEmpty) {
      return _roleLabel(_jokerFakeRole!);
    }
    return _roleLabel(_myRole);
  }

  String _roleDescription(String role, {String? fakeRole}) {
    if (role == 'mafia') {
      return '역할: 마피아 · 밤에 플레이어 1명을 탈락 대상으로 지정할 수 있습니다.';
    }
    if (role == 'doctor') {
      return '역할: 의사 · 밤에 플레이어 1명을 치료할 수 있으며, 자기 치료는 연속 사용이 불가능합니다.';
    }
    if (role == 'police') {
      return '역할: 경찰 · 밤에 플레이어 1명을 조사해 직업 정보를 확인할 수 있습니다.';
    }
    if (role == 'joker') {
      final masked = fakeRole == null || fakeRole.isEmpty ? '미정' : _roleLabel(fakeRole);
      return '역할: $masked · 밤에 해당 직업의 능력을 사용할 수 있습니다.';
    }
    return '역할: 시민 · 특별한 밤 능력은 없습니다.';
  }

  InlineSpan _chatMessageSpan(BuildContext context, ChatItem item) {
    final message = item.message;
    final defaultColor = Theme.of(context).textTheme.bodyMedium?.color;
    if (message.isEmpty) {
      return TextSpan(text: '', style: TextStyle(color: defaultColor));
    }
    if (item.highlightDanger) {
      return TextSpan(
        text: message,
        style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700),
      );
    }

    final pattern = RegExp('탈락|처형|생존|치료로 생존');
    final spans = <TextSpan>[];
    int cursor = 0;
    for (final match in pattern.allMatches(message)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: message.substring(cursor, match.start),
            style: TextStyle(color: defaultColor),
          ),
        );
      }
      final token = message.substring(match.start, match.end);
      final isSurvive = token.contains('생존');
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(
            color: isSurvive ? Colors.lightBlueAccent : Colors.redAccent,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < message.length) {
      spans.add(
        TextSpan(
          text: message.substring(cursor),
          style: TextStyle(color: defaultColor),
        ),
      );
    }
    return TextSpan(children: spans);
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

  Widget _helpTabContent(BuildContext context, List<String> lines) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines
            .map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $line',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _modalSwitchRow(BuildContext dialogContext, {required String current}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.start,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: current == 'action'
                    ? null
                    : (_inRoom
                        ? () {
                            Navigator.of(dialogContext).pop();
                            Future.microtask(_showActionModal);
                          }
                        : null),
                icon: const Icon(Icons.lock, size: 16),
                label: const Text('개인로그'),
              ),
              TextButton.icon(
                onPressed: current == 'players'
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        Future.microtask(_showPlayersModal);
                      },
                icon: const Icon(Icons.groups_2, size: 16),
                label: const Text('유저목록'),
              ),
              TextButton.icon(
                onPressed: current == 'help'
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        Future.microtask(_showRulesHelpModal);
                      },
                icon: const Icon(Icons.help_outline, size: 16),
                label: const Text('도움말'),
              ),
              TextButton.icon(
                onPressed: current == 'settings'
                    ? null
                    : () {
                        Navigator.of(dialogContext).pop();
                        Future.microtask(_showGameSettingsModal);
                      },
                icon: const Icon(Icons.settings, size: 16),
                label: const Text('게임설정'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRulesHelpModal() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Center(
            child: FractionallySizedBox(
              widthFactor: _unifiedModalWidthFactor,
              heightFactor: _unifiedModalHeightFactor,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xCC11131B),
                    border: Border.all(color: const Color(0x44FFFFFF)),
                  ),
                  child: DefaultTabController(
                    length: 3,
                    child: Column(
                      children: [
                        _modalSwitchRow(context, current: 'help'),
                        Container(
                          color: const Color(0x551B1D25),
                          child: const TabBar(
                            isScrollable: true,
                            tabs: [
                              Tab(text: '직업 설명'),
                              Tab(text: '오리지널 마피아 규칙'),
                              Tab(text: 'Moral Roulette 규칙'),
                            ],
                          ),
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              _helpTabContent(
                                context,
                                const [
                                  '시민: 특별한 밤 능력이 없습니다.',
                                  '마피아: 밤에 1명을 탈락 대상으로 지정합니다.',
                                  '의사: 밤에 1명을 치료할 수 있고, 자기 자신 연속 치료는 불가능합니다.',
                                  '경찰: 밤에 1명을 조사해 직업 정보를 확인합니다.',
                                  '조커(시민 편): 게임 시작 시 위장 직업이 배정되며, 해당 직업의 능력을 사용합니다.',
                                ],
                              ),
                              _helpTabContent(
                                context,
                                const [
                                  '직업은 게임 시작 시 배정되고 게임 종료까지 유지됩니다.',
                                  '밤(능력 사용) → 아침(투표) → 처형 찬반 순서로 진행됩니다.',
                                  '마피아가 모두 제거되면 시민 승리입니다.',
                                  '마피아 수가 시민 수를 초과하면 마피아 승리입니다.',
                                  '오리지널 모드는 점수제가 아니라 승패 중심 모드입니다.',
                                ],
                              ),
                              _helpTabContent(
                                context,
                                const [
                                  '매일 시작 시 생존 인원 기준으로 직업이 자동 재배정됩니다.',
                                  '밤(능력 사용) → 아침(투표) → 처형 찬반 → 마피아 진행 선택 순서로 진행됩니다.',
                                  '마피아 생존 점수는 조커 인원 구간(2+/1/0명)에 대해 설정한 점수값을 획득합니다.',
                                  '2마피아 체제에서 1명이 탈락해 1마피아가 되면, 해당 전환 턴은 마피아 생존 점수 미지급 + 남은 마피아 역할 1턴 유지 + 자동 계속 진행 처리됩니다.',
                                  '시민 편 종료 보너스: 시민/중단 종료는 n일차×설정배수, 마피아 승리 종료는 n일차×1이 지급됩니다.',
                                  '3인(시민편 2 + 마피아 1)에서 1대1(시민편 1 + 마피아 1) 성립 시 마피아 +10점 후 자동 종료됩니다.',
                                ],
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                              label: const Text('닫기'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool _isImportantSummaryLog(String item) {
    if (item.startsWith(kDangerLogPrefix)) return true;
    if (item.contains('역할:')) return false;
    final rest = item.startsWith('[') && item.contains('] ')
        ? item.substring(item.indexOf('] ') + 2)
        : item;
    const keywords = [
      '투표',
      '처형',
      '찬성',
      '반대',
      '기권',
      '치료',
      '조사',
      '능력',
      '탈락',
      '결과',
      '확정',
    ];
    return keywords.any(rest.contains);
  }

  List<String> _importantSummaryLogs() {
    return _privateLogs.where(_isImportantSummaryLog).toList(growable: false);
  }

  InlineSpan _summaryLogSpan(BuildContext context, String item) {
    final closeIdx = item.indexOf('] ');
    final hasDayPrefix = item.startsWith('[') && closeIdx > 0;
    final prefix = hasDayPrefix ? item.substring(0, closeIdx + 1) : null;
    final rawRest = hasDayPrefix ? item.substring(closeIdx + 2) : item;
    final isDanger = rawRest.startsWith(kDangerLogPrefix);
    final rest = isDanger ? rawRest.substring(kDangerLogPrefix.length) : rawRest;

    const boldKeywords = [
      '투표',
      '처형',
      '찬성',
      '반대',
      '기권',
      '치료',
      '조사',
      '능력',
      '탈락',
      '결과',
      '확정',
    ];
    final pattern = RegExp(boldKeywords.map(RegExp.escape).join('|'));
    final baseColor = Theme.of(context).textTheme.bodyMedium?.color;
    final spans = <TextSpan>[];
    int cursor = 0;
    for (final match in pattern.allMatches(rest)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: rest.substring(cursor, match.start),
            style: TextStyle(
              color: isDanger ? Colors.redAccent : baseColor,
              fontWeight: isDanger ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: rest.substring(match.start, match.end),
          style: TextStyle(
            color: isDanger ? Colors.redAccent : baseColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < rest.length) {
      spans.add(
        TextSpan(
          text: rest.substring(cursor),
          style: TextStyle(
            color: isDanger ? Colors.redAccent : baseColor,
            fontWeight: isDanger ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      );
    }

    if (prefix == null) {
      return TextSpan(children: spans);
    }
    return TextSpan(
      children: [
        TextSpan(
          text: '$prefix ',
          style: const TextStyle(
            color: Colors.white60,
            fontWeight: FontWeight.w600,
          ),
        ),
        ...spans,
      ],
    );
  }

  void _showGameSettingsModal() {
    final room = _room;
    if (room == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('방에 입장한 뒤 설정을 변경할 수 있습니다.'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        String settingsTab = _settingsTab;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _refreshSettingsModal = () {
              if (!mounted || _isDisposing) return;
              setDialogState(() {});
            };
            final currentRoom = _room;
            if (currentRoom == null) {
              return Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: _unifiedModalWidthFactor,
                    heightFactor: _unifiedModalHeightFactor,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xCC11131B),
                          border: Border.all(color: const Color(0x44FFFFFF)),
                        ),
                        child: Column(
                          children: [
                            _modalSwitchRow(context, current: 'settings'),
                            const Expanded(child: Center(child: Text('방 정보가 없습니다.'))),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: _unifiedModalWidthFactor,
                  heightFactor: _unifiedModalHeightFactor,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xCC11131B),
                        border: Border.all(color: const Color(0x44FFFFFF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _modalSwitchRow(context, current: 'settings'),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                            color: const Color(0x551B1D25),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                ChoiceChip(
                                  label: const Text('게임 설정'),
                                  selected: settingsTab == 'game',
                                  onSelected: (_) {
                                    setDialogState(() {
                                      settingsTab = 'game';
                                      _settingsTab = 'game';
                                    });
                                  },
                                ),
                                ChoiceChip(
                                  label: const Text('점수 설정'),
                                  selected: settingsTab == 'score',
                                  onSelected: (_) {
                                    setDialogState(() {
                                      settingsTab = 'score';
                                      _settingsTab = 'score';
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (settingsTab == 'game') ...[
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        ChoiceChip(
                                          label: const Text('오리지널 마피아'),
                                          selected: currentRoom.game.mode == 'original',
                                          onSelected: (_isHost && !currentRoom.game.inProgress)
                                              ? (_) {
                                                  _setGameMode('original');
                                                  setDialogState(() {});
                                                }
                                              : null,
                                        ),
                                        ChoiceChip(
                                          label: const Text('Moral Roulette'),
                                          selected: currentRoom.game.mode == 'moral_roulette',
                                          onSelected: (_isHost && !currentRoom.game.inProgress)
                                              ? (_) {
                                                  _setGameMode('moral_roulette');
                                                  setDialogState(() {});
                                                }
                                              : null,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '현재 모드: ${_modeLabel(currentRoom.game.mode)}',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    for (final roleKey in ['mafia', 'doctor', 'police', 'joker'])
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${_roleLabel(roleKey)} 인원',
                                                style: Theme.of(context).textTheme.bodyMedium,
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: (_isHost &&
                                                      !currentRoom.game.inProgress &&
                                                      (currentRoom.game.mode != 'moral_roulette' || roleKey == 'joker'))
                                                  ? () {
                                                      _adjustRoleCount(roleKey, -1);
                                                      setDialogState(() {});
                                                    }
                                                  : null,
                                              icon: const Icon(Icons.remove_circle_outline),
                                            ),
                                            SizedBox(
                                              width: 26,
                                              child: Text(
                                                '${currentRoom.game.roleCounts[roleKey] ?? 0}',
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: (_isHost &&
                                                      !currentRoom.game.inProgress &&
                                                      (currentRoom.game.mode != 'moral_roulette' || roleKey == 'joker'))
                                                  ? () {
                                                      _adjustRoleCount(roleKey, 1);
                                                      setDialogState(() {});
                                                    }
                                                  : null,
                                              icon: const Icon(Icons.add_circle_outline),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (!_isHost)
                                      Text(
                                        '게임 모드/직업 수 설정은 호스트만 변경할 수 있습니다.',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                    if (_isHost && currentRoom.game.mode == 'moral_roulette')
                                      Text(
                                        'Moral Roulette는 마피아/의사/경찰은 자동이며, 조커 인원은 수동 조정할 수 있습니다.',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                  ],
                                  if (settingsTab == 'score') ...[
                                    Text(
                                      '마피아 점수 (조커 인원 기준)',
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    for (final config in [
                                      ('mafiaJoker2Plus', '조커 2명 이상', currentRoom.game.scoreSettings['mafiaJoker2Plus'] ?? 2),
                                      ('mafiaJoker1', '조커 1명', currentRoom.game.scoreSettings['mafiaJoker1'] ?? 4),
                                      ('mafiaJoker0', '조커 0명', currentRoom.game.scoreSettings['mafiaJoker0'] ?? 6),
                                    ])
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${config.$2} 점수',
                                                style: Theme.of(context).textTheme.bodyMedium,
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: (_isHost && !currentRoom.game.inProgress && currentRoom.game.mode == 'moral_roulette')
                                                  ? () {
                                                      final next = (config.$3 - 1).clamp(0, 99);
                                                      if (config.$1 == 'mafiaJoker2Plus') {
                                                        _setScoreSettings(mafiaJoker2Plus: next);
                                                      } else if (config.$1 == 'mafiaJoker1') {
                                                        _setScoreSettings(mafiaJoker1: next);
                                                      } else {
                                                        _setScoreSettings(mafiaJoker0: next);
                                                      }
                                                      setDialogState(() {});
                                                    }
                                                  : null,
                                              icon: const Icon(Icons.remove_circle_outline),
                                            ),
                                            SizedBox(
                                              width: 34,
                                              child: Text(
                                                '${config.$3}',
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: (_isHost && !currentRoom.game.inProgress && currentRoom.game.mode == 'moral_roulette')
                                                  ? () {
                                                      final next = (config.$3 + 1).clamp(0, 99);
                                                      if (config.$1 == 'mafiaJoker2Plus') {
                                                        _setScoreSettings(mafiaJoker2Plus: next);
                                                      } else if (config.$1 == 'mafiaJoker1') {
                                                        _setScoreSettings(mafiaJoker1: next);
                                                      } else {
                                                        _setScoreSettings(mafiaJoker0: next);
                                                      }
                                                      setDialogState(() {});
                                                    }
                                                  : null,
                                              icon: const Icon(Icons.add_circle_outline),
                                            ),
                                          ],
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '시민 종료 점수 배수',
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '시민/중단 종료 시 n × 배수',
                                            style: Theme.of(context).textTheme.bodyMedium,
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: (_isHost && !currentRoom.game.inProgress && currentRoom.game.mode == 'moral_roulette')
                                              ? () {
                                                  final current = currentRoom.game.scoreSettings['citizenEndMultiplier'] ?? 2;
                                                  _setScoreSettings(citizenEndMultiplier: (current - 1).clamp(0, 99));
                                                  setDialogState(() {});
                                                }
                                              : null,
                                          icon: const Icon(Icons.remove_circle_outline),
                                        ),
                                        SizedBox(
                                          width: 34,
                                          child: Text(
                                            '${currentRoom.game.scoreSettings['citizenEndMultiplier'] ?? 2}',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: (_isHost && !currentRoom.game.inProgress && currentRoom.game.mode == 'moral_roulette')
                                              ? () {
                                                  final current = currentRoom.game.scoreSettings['citizenEndMultiplier'] ?? 2;
                                                  _setScoreSettings(citizenEndMultiplier: (current + 1).clamp(0, 99));
                                                  setDialogState(() {});
                                                }
                                              : null,
                                          icon: const Icon(Icons.add_circle_outline),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '마피아 승리 시 시민 편 보너스는 항상 n × 1로 고정됩니다.',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      currentRoom.game.mode == 'moral_roulette'
                                          ? (_isHost
                                              ? '점수 방식은 호스트가 변경할 수 있습니다.'
                                              : '점수 방식은 호스트만 변경할 수 있습니다.')
                                          : '점수 설정은 Moral Roulette 모드에서만 적용됩니다.',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close),
                                label: const Text('닫기'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _refreshSettingsModal = null;
    });
  }

  void _showPlayersModal() {
    if (_room == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('방에 입장한 뒤 유저 목록을 확인할 수 있습니다.'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _refreshPlayersModal = () {
              if (!mounted || _isDisposing) return;
              setDialogState(() {});
            };
            final currentRoom = _room;
            final players = currentRoom?.players ?? const <PlayerInfo>[];
            final isVotingPhase = currentRoom?.game.phase == 'voting';
            final canAbstainVote = isVotingPhase && !_isMyEliminated;

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: _unifiedModalWidthFactor,
                  heightFactor: _unifiedModalHeightFactor,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xCC11131B),
                        border: Border.all(color: const Color(0x44FFFFFF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _modalSwitchRow(context, current: 'players'),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                            child: _sectionTitle(context, '유저 목록 (투표 선택)', icon: Icons.groups),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: canAbstainVote
                                        ? () {
                                            Navigator.of(context).pop();
                                            _castVote(null);
                                          }
                                        : null,
                                    icon: const Icon(Icons.remove_circle_outline),
                                    label: const Text('기권 투표'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!isVotingPhase)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                              child: Text(
                                '기권 투표는 처형 투표 단계에서만 가능합니다.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                              child: GridView.builder(
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  crossAxisSpacing: 6,
                                  mainAxisSpacing: 6,
                                  mainAxisExtent: 66,
                                ),
                                itemCount: players.length,
                                itemBuilder: (context, index) {
                                  final player = players[index];
                                  final eliminated = currentRoom?.game.eliminatedIds.contains(player.id) ?? false;
                                  final canVote = (!_isMyEliminated || player.id == _myPlayerId) && !eliminated;
                                  final isMafiaMate = _myRole == 'mafia' && _mafiaTeammateIds.contains(player.id);
                                  final label = '${player.name}${player.id == _myPlayerId ? ' (나)' : ''}${eliminated ? ' (탈락)' : ''}';

                                  return FilledButton.tonal(
                                    onPressed: canVote
                                        ? () {
                                            Navigator.of(context).pop();
                                            _onPlayerSelect(player.id);
                                          }
                                        : null,
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: Text(
                                      label,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                        color: isMafiaMate ? Colors.redAccent : null,
                                        fontWeight: isMafiaMate ? FontWeight.w700 : FontWeight.w500,
                                        letterSpacing: 0.15,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close),
                                label: const Text('닫기'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _refreshPlayersModal = null;
    });
  }

  void _showActionModal() {
    if (_room == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('방에 입장한 뒤 개인 로그를 확인할 수 있습니다.'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _refreshActionModal = () {
              if (!mounted || _isDisposing) return;
              setDialogState(() {});
            };
            final room = _room;
            if (room == null) {
              return Dialog(
                backgroundColor: Colors.transparent,
                insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: _unifiedModalWidthFactor,
                    heightFactor: _unifiedModalHeightFactor,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xCC11131B),
                          border: Border.all(color: const Color(0x44FFFFFF)),
                        ),
                        child: const Center(child: Text('방 정보가 없습니다.')),
                      ),
                    ),
                  ),
                ),
              );
            }

            final players = room.players;
            final roleColor = _myRole == 'mafia'
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.tertiary;
            final summaryLogs = _importantSummaryLogs();

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: _unifiedModalWidthFactor,
                  heightFactor: _unifiedModalHeightFactor,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xCC11131B),
                        border: Border.all(color: const Color(0x44FFFFFF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _modalSwitchRow(context, current: 'action'),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                            child: _sectionTitle(context, '개인 로그', icon: Icons.lock),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      Chip(
                                        avatar: const Icon(Icons.tag, size: 16),
                                        label: Text('ROOM ${room.id}'),
                                      ),
                                      Chip(
                                        avatar: const Icon(Icons.schedule, size: 16),
                                        label: Text('DAY ${room.game.day} · ${_phaseLabel(room.game.phase)}'),
                                      ),
                                      Chip(
                                        avatar: Icon(Icons.person, size: 16, color: roleColor),
                                        label: Text(
                                          '내 역할 ${_displayRoleLabelInGame()}',
                                        ),
                                      ),
                                      Chip(
                                        avatar: const Icon(Icons.group, size: 16),
                                        label: Text('인원 ${players.length}명'),
                                      ),
                                      if (_isMyEliminated)
                                        const Chip(
                                          avatar: Icon(Icons.block, size: 16),
                                          label: Text('탈락 상태'),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  _sectionTitle(context, '요약 기록', icon: Icons.summarize),
                                  const SizedBox(height: 4),
                                  if (summaryLogs.isEmpty)
                                    Text(
                                      '게임 시작 이후 능력 사용 결과와 투표 결과가 누적되면 이곳에 요약됩니다.',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    )
                                  else
                                    for (final item in summaryLogs.reversed.take(12))
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 2),
                                        child: RichText(
                                          text: TextSpan(
                                            style: Theme.of(context).textTheme.bodyMedium,
                                            children: [
                                              const TextSpan(text: '• '),
                                              _summaryLogSpan(context, item),
                                            ],
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close),
                                label: const Text('닫기'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _refreshActionModal = null;
    });
  }

  Widget _panel({required Widget child}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: child,
      ),
    );
  }

  Widget _creatorFooter(BuildContext context) {
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 24,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 10, 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              '제작자 : gohy3707@naver.com',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: Colors.white70,
                  ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final shortestSide = screenSize.shortestSide;
    final uiScale = (shortestSide / 390).clamp(0.9, 1.08).toDouble();
    double scaled(double value, {double min = 0, double max = double.infinity}) {
      return (value * uiScale).clamp(min, max).toDouble();
    }
    final authCardWidth = (screenSize.width * 0.92).clamp(300.0, 360.0).toDouble();
    final statusTextWidth = (screenSize.width * 0.78).clamp(220.0, 320.0).toDouble();
    final appBarLogoHeight = scaled(28, min: 24, max: 30);
    final chatBoxHeight = (screenSize.height * 0.46).clamp(260.0, 420.0).toDouble();
    final chatBubbleMaxWidth = (screenSize.width * 0.72).clamp(220.0, 360.0).toDouble();
    final quickEmojiSize = Size(
      scaled(34, min: 30, max: 38),
      scaled(30, min: 28, max: 34),
    );
    final quickEmojiPadding = EdgeInsets.symmetric(
      horizontal: scaled(6, min: 4, max: 8),
      vertical: scaled(3, min: 2, max: 5),
    );
    final quickEmojiFontSize = scaled(16, min: 14, max: 18);
    final compactControlHeight = scaled(34, min: 30, max: 36);
    final compactButtonPadding = EdgeInsets.symmetric(
      horizontal: scaled(8, min: 6, max: 10),
      vertical: scaled(4, min: 2, max: 5),
    );

    if (_serverEndpoint == null && !_isConnecting && _myPlayerId == null) {
      return Scaffold(
        bottomNavigationBar: _creatorFooter(context),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF121218), Color(0xFF0A0B10)],
            ),
          ),
          child: Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: authCardWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('서버 선택', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      const Text('플레이 방식을 선택하세요.'),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _selectPublicServer,
                          style: ElevatedButton.styleFrom(
                            minimumSize: Size.fromHeight(compactControlHeight),
                            padding: compactButtonPadding,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.public),
                          label: const Text('공용 서버로 플레이'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _lanServerController,
                        decoration: const InputDecoration(labelText: 'LAN 주소 (예: ws://192.168.0.10:8080)'),
                      ),
                      const SizedBox(height: 3),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isDiscoveringLan ? null : _discoverAndSelectLanServer,
                          style: ElevatedButton.styleFrom(
                            minimumSize: Size.fromHeight(compactControlHeight),
                            padding: compactButtonPadding,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.wifi_tethering),
                          label: Text(_isDiscoveringLan ? 'LAN 탐색 중...' : 'LAN 자동 탐색 후 연결'),
                        ),
                      ),
                      const SizedBox(height: 3),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _selectLanServer,
                          style: OutlinedButton.styleFrom(
                            minimumSize: Size.fromHeight(compactControlHeight),
                            padding: compactButtonPadding,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.router),
                          label: const Text('입력한 LAN 주소로 연결'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (_isConnecting) {
      return Scaffold(
        bottomNavigationBar: _creatorFooter(context),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF121218), Color(0xFF0A0B10)],
            ),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3)),
                SizedBox(height: 8),
                Text('서버 연결 중...'),
              ],
            ),
          ),
        ),
      );
    }

    if (_myPlayerId == null) {
      return Scaffold(
        bottomNavigationBar: _creatorFooter(context),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF121218), Color(0xFF0A0B10)],
            ),
          ),
          child: Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, size: 34),
                    const SizedBox(height: 4),
                    const Text('서버 연결 실패'),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: statusTextWidth,
                      child: Text(
                        _status,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: statusTextWidth,
                      child: Text(
                        '서버 주소: ${_serverEndpoint ?? '-'}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ElevatedButton.icon(
                      onPressed: _connect,
                      style: ElevatedButton.styleFrom(
                        minimumSize: Size.fromHeight(compactControlHeight),
                        padding: compactButtonPadding,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('다시 연결'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final isAbilityPhase = _room?.game.inProgress == true && _room?.game.phase == 'ability';
    final canUseMafiaNightChat = isAbilityPhase && _myRole == 'mafia' && !_isMyEliminated;
    final canUseTextChat = !isAbilityPhase || canUseMafiaNightChat;
    final canUseEmojiChat = !isAbilityPhase || !_isMyEliminated;
    final search = _roomSearchController.text.trim().toLowerCase();
    final filteredRooms = _availableRooms.where((roomInfo) {
      if (_waitingOnly && roomInfo.inProgress) return false;
      if (search.isEmpty) return true;
      return roomInfo.id.toLowerCase().contains(search) ||
        roomInfo.hostName.toLowerCase().contains(search);
    }).toList();

    return Scaffold(
      bottomNavigationBar: _creatorFooter(context),
      appBar: AppBar(
        centerTitle: false,
        title: Image.asset(
          'image/Moral_Roulette_icon.png',
          height: appBarLogoHeight,
          fit: BoxFit.contain,
        ),
        actions: [
          if (_inRoom)
            IconButton(
              onPressed: _showActionModal,
              tooltip: '개인 로그',
              icon: const Icon(Icons.lock),
            ),
          if (_inRoom)
            IconButton(
              onPressed: _showPlayersModal,
              tooltip: '유저 목록',
              icon: const Icon(Icons.groups_2),
            ),
          IconButton(
            onPressed: _showRulesHelpModal,
            tooltip: '게임 규칙/직업 설명',
            icon: const Icon(Icons.help_outline),
          ),
          if (_inRoom)
            IconButton(
              onPressed: _showGameSettingsModal,
              tooltip: '게임 설정',
              icon: const Icon(Icons.settings),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Chip(
                label: Text(_connected ? 'ON' : 'OFFLINE'),
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
          padding: const EdgeInsets.all(6),
          children: [
            if (!_inRoom) ...[
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(context, '입장 허브', icon: Icons.vpn_key),
                    const SizedBox(height: 3),
                    Text(
                      '코드를 입력해 입장하거나, 자동 코드로 빠르게 방을 만들 수 있습니다.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _nameController,
                            onSubmitted: (_) => _applyNickname(),
                            decoration: const InputDecoration(labelText: '닉네임 입력(입장 전 변경)'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _connected ? _applyNickname : null,
                          style: ElevatedButton.styleFrom(
                            minimumSize: Size(0, compactControlHeight),
                            padding: compactButtonPadding,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('변경'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _roomController,
                      decoration: const InputDecoration(labelText: '방 코드 입력'),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _connected ? _joinRoom : null,
                            style: ElevatedButton.styleFrom(
                              minimumSize: Size.fromHeight(compactControlHeight),
                              padding: compactButtonPadding,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('코드로 입장'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _connected ? _createRoom : null,
                            style: OutlinedButton.styleFrom(
                              minimumSize: Size.fromHeight(compactControlHeight),
                              padding: compactButtonPadding,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('코드로 생성'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _connected ? _createAutoRoom : null,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size.fromHeight(compactControlHeight),
                          padding: compactButtonPadding,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
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
                    const SizedBox(height: 3),
                    TextField(
                      controller: _roomSearchController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '방 코드/호스트 검색',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 3),
                    SwitchListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -3),
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
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(6),
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
                              style: ElevatedButton.styleFrom(
                                minimumSize: Size(0, compactControlHeight),
                                padding: compactButtonPadding,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
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
                    _sectionTitle(context, '채팅', icon: Icons.chat_bubble),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (_isHost && !(_room?.game.inProgress ?? false))
                          Expanded(
                            child: ElevatedButton(
                              onPressed: (_room?.game.canStart ?? false) ? () => _send({'type': 'start_game'}) : null,
                              style: ElevatedButton.styleFrom(
                                minimumSize: Size.fromHeight(compactControlHeight),
                                padding: compactButtonPadding,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('게임 시작'),
                            ),
                          ),
                        if (_isHost && !(_room?.game.inProgress ?? false)) const SizedBox(width: 4),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _connected && _inRoom && !(_room?.game.inProgress ?? false)
                                ? () => _send({'type': 'leave_room'})
                                : null,
                            style: OutlinedButton.styleFrom(
                              minimumSize: Size.fromHeight(compactControlHeight),
                              padding: compactButtonPadding,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('방 나가기'),
                          ),
                        ),
                      ],
                    ),
                    if (_room?.game.phase == 'execution_vote') ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: !_isMyEliminated ? () => _castExecutionVote(true) : null,
                              style: ElevatedButton.styleFrom(
                                minimumSize: Size.fromHeight(compactControlHeight),
                                padding: compactButtonPadding,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.how_to_vote),
                              label: const Text('찬성'),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: !_isMyEliminated ? () => _castExecutionVote(false) : null,
                              style: OutlinedButton.styleFrom(
                                minimumSize: Size.fromHeight(compactControlHeight),
                                padding: compactButtonPadding,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.block),
                              label: const Text('반대'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_room?.game.phase == 'mafia_decision') ...[
                      const SizedBox(height: 3),
                      if (_myRole == 'mafia' && !_isMyEliminated)
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _setMafiaContinue(true),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: Size.fromHeight(compactControlHeight),
                                  padding: compactButtonPadding,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('계속 진행'),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _setMafiaContinue(false),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: Size.fromHeight(compactControlHeight),
                                  padding: compactButtonPadding,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text('중지'),
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          '마피아 진행 선택 대기 중입니다.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (_room?.game.phaseDurationSec != null && _room?.game.phaseEndsAt != null)
                                    ? '제한시간 ${_remainSeconds(_room!.game)} / ${_room!.game.phaseDurationSec}초'
                                    : '채팅 외 조작은 상단 개인로그/유저목록/설정 모달에서 진행하세요.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (_room?.game.phaseDurationSec != null && _room?.game.phaseEndsAt != null) ...[
                                SizedBox(height: scaled(3, min: 2, max: 4)),
                                LinearProgressIndicator(
                                  value: _phaseProgress(_room!.game),
                                  minHeight: 7,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'DAY ${_room?.game.day ?? 0} · ${_phaseLabel(_room?.game.phase ?? 'lobby')}',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            Text(
                              '내 역할 ${_displayRoleLabelInGame()}',
                              style: Theme.of(context).textTheme.labelSmall,
                              textAlign: TextAlign.right,
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (_unreadChatCount > 0)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _jumpToLatestChat,
                          icon: const Icon(Icons.arrow_downward, size: 16),
                          label: Text('새 메시지 $_unreadChatCount개'),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Container(
                      height: chatBoxHeight,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF12141C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: ListView.builder(
                        controller: _chatScrollController,
                        itemCount: _chatLogs.length,
                        itemBuilder: (context, index) {
                          final item = _chatLogs[index];
                          if (item.centerNotice) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Center(
                                child: Text(
                                  item.message,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        color: Colors.redAccent,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ),
                            );
                          }
                          final isMine = item.fromId != null && item.fromId == _myPlayerId;
                          final bubbleColor = item.system
                              ? Theme.of(context).colorScheme.surfaceContainerHighest
                              : isMine
                                  ? const Color(0xFF40315A)
                                  : const Color(0xFF232736);

                          return Align(
                            alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              constraints: BoxConstraints(maxWidth: chatBubbleMaxWidth),
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
                                  const SizedBox(height: 0),
                                  if (item.imageAsset != null && item.imageAsset!.isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 2),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Image.asset(
                                          'image/${item.imageAsset!}',
                                          height: scaled(120, min: 96, max: 128),
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (item.message.isNotEmpty)
                                    (item.isEmoji
                                        ? Text(
                                            item.message,
                                            style: Theme.of(context).textTheme.headlineSmall,
                                          )
                                        : RichText(
                                            text: TextSpan(
                                              style: Theme.of(context).textTheme.bodyMedium,
                                              children: [_chatMessageSpan(context, item)],
                                            ),
                                          )),
                                  if (item.ts != null) ...[
                                    const SizedBox(height: 0),
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
                    const SizedBox(height: 4),
                    if (!canUseTextChat)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '밤 능력 단계에서는 텍스트 채팅을 사용할 수 없습니다. (이모티콘 채팅 가능)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (canUseMafiaNightChat)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '밤 능력 단계 마피아 전용 채팅 중입니다. (다른 플레이어에게 보이지 않음)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Wrap(
                      spacing: 2,
                      runSpacing: 2,
                      children: kQuickEmojis
                          .map(
                            (emoji) => OutlinedButton(
                              onPressed: canUseEmojiChat ? () => _sendEmoji(emoji) : null,
                              style: OutlinedButton.styleFrom(
                                minimumSize: quickEmojiSize,
                                padding: quickEmojiPadding,
                              ),
                              child: Text(emoji, style: TextStyle(fontSize: quickEmojiFontSize)),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            enabled: canUseTextChat,
                            decoration: const InputDecoration(labelText: '메시지'),
                          ),
                        ),
                        const SizedBox(width: 4),
                        ElevatedButton.icon(
                          onPressed: canUseTextChat ? _sendChat : null,
                          icon: const Icon(Icons.send),
                          label: const Text('전송'),
                        ),
                      ],
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
    required this.mode,
    required this.roleCounts,
    required this.scoreSettings,
    required this.executionCandidateId,
    required this.executionVotes,
    required this.canStart,
    required this.eliminatedIds,
    this.phaseEndsAt,
    this.phaseDurationSec,
  });

  final bool inProgress;
  final int day;
  final String phase;
  final String mode;
  final Map<String, int> roleCounts;
  final Map<String, int> scoreSettings;
  final String? executionCandidateId;
  final Map<String, bool> executionVotes;
  final bool canStart;
  final Set<String> eliminatedIds;
  final int? phaseEndsAt;
  final int? phaseDurationSec;

  String executionCandidateName(List<PlayerInfo> players) {
    final candidateId = executionCandidateId;
    if (candidateId == null || candidateId.isEmpty) {
      return '-';
    }
    final found = players.where((player) => player.id == candidateId);
    if (found.isEmpty) {
      return candidateId;
    }
    return found.first.name;
  }

  factory GameState.fromJson(Map<String, dynamic> json) {
    final eliminated = (json['eliminatedIds'] as List<dynamic>? ?? [])
        .map((item) => item.toString())
        .toSet();
    final rawRoleCounts = (json['roleCounts'] as Map<String, dynamic>? ?? {});
    final rawScoreSettings = (json['scoreSettings'] as Map<String, dynamic>? ?? {});
    final rawExecutionVotes = (json['executionVotes'] as Map<String, dynamic>? ?? {});
    final roleCounts = {
      'mafia': (rawRoleCounts['mafia'] as int?) ?? 1,
      'doctor': (rawRoleCounts['doctor'] as int?) ?? 1,
      'police': (rawRoleCounts['police'] as int?) ?? 1,
      'joker': (rawRoleCounts['joker'] as int?) ?? 0,
    };
    final executionVotes = <String, bool>{
      for (final entry in rawExecutionVotes.entries)
        entry.key: entry.value == true,
    };
    int asInt(dynamic value, int fallback) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }
    final scoreSettings = {
      'mafiaJoker2Plus': asInt(rawScoreSettings['mafiaJoker2Plus'], 2),
      'mafiaJoker1': asInt(rawScoreSettings['mafiaJoker1'], 4),
      'mafiaJoker0': asInt(rawScoreSettings['mafiaJoker0'], 6),
      'citizenEndMultiplier': asInt(rawScoreSettings['citizenEndMultiplier'], 2),
    };
    return GameState(
      inProgress: json['inProgress'] as bool? ?? false,
      day: json['day'] as int? ?? 0,
      phase: json['phase'] as String? ?? 'lobby',
      mode: json['mode'] as String? ?? 'moral_roulette',
      roleCounts: roleCounts,
      scoreSettings: scoreSettings,
      executionCandidateId: json['executionCandidateId'] as String?,
      executionVotes: executionVotes,
      canStart: json['canStart'] as bool? ?? false,
      eliminatedIds: eliminated,
      phaseEndsAt: json['phaseEndsAt'] as int?,
      phaseDurationSec: json['phaseDurationSec'] as int?,
    );
  }
}

class ChatItem {
  ChatItem({
    this.fromId,
    required this.fromName,
    required this.message,
    required this.system,
    required this.centerNotice,
    required this.isEmoji,
    this.imageAsset,
    required this.highlightDanger,
    this.ts,
  });

  final String? fromId;
  final String fromName;
  final String message;
  final bool system;
  final bool centerNotice;
  final bool isEmoji;
  final String? imageAsset;
  final bool highlightDanger;
  final int? ts;

  factory ChatItem.fromJson(Map<String, dynamic> json) {
    return ChatItem(
      fromId: json['fromId'] as String?,
      fromName: json['fromName'] as String? ?? 'unknown',
      message: json['message'] as String? ?? '',
      system: json['system'] as bool? ?? false,
      centerNotice: json['centerNotice'] as bool? ?? false,
      isEmoji: json['isEmoji'] as bool? ?? false,
      imageAsset: json['imageAsset'] as String?,
      highlightDanger: json['highlightDanger'] as bool? ?? false,
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
