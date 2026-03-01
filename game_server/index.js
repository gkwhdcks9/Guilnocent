const express = require("express");
const cors = require("cors");
const http = require("http");
const { WebSocketServer } = require("ws");

const app = express();
app.use(cors());
app.use(express.json());

app.get("/health", (_, res) => {
  res.json({ ok: true, now: new Date().toISOString() });
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = Number(process.env.PORT || 8080);

const rooms = new Map();
const players = new Map();

function randomId(prefix = "id") {
  return `${prefix}_${Math.random().toString(36).slice(2, 10)}`;
}

function safeSend(ws, payload) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function getRoom(roomId) {
  return rooms.get(roomId);
}

function playerPublicInfo(player) {
  return {
    id: player.id,
    name: player.name,
    score: player.score,
  };
}

function roomSnapshot(room) {
  const game = room.game;
  const playerList = [...room.players.values()].map((playerId) =>
    playerPublicInfo(players.get(playerId))
  );

  return {
    id: room.id,
    hostId: room.hostId,
    players: playerList,
    game: {
      inProgress: game.inProgress,
      day: game.day,
      phase: game.phase,
      votes: game.votes,
      mafiaContinue: game.mafiaContinue,
      lastExecutedId: game.lastExecutedId,
      lastVoteResult: game.lastVoteResult,
      canStart: playerList.length >= 3,
    },
  };
}

function roomsListSnapshot() {
  return [...rooms.values()]
    .map((room) => {
      const hostName = players.get(room.hostId)?.name || "unknown";
      return {
        id: room.id,
        hostId: room.hostId,
        hostName,
        playerCount: room.players.size,
        inProgress: room.game.inProgress,
        day: room.game.day,
        phase: room.game.phase,
      };
    })
    .sort((a, b) => b.playerCount - a.playerCount || a.id.localeCompare(b.id));
}

function broadcastRoomsList() {
  const payload = { type: "rooms_list", rooms: roomsListSnapshot() };
  for (const player of players.values()) {
    safeSend(player.ws, payload);
  }
}

function sendRoomsList(player) {
  safeSend(player.ws, { type: "rooms_list", rooms: roomsListSnapshot() });
}

function broadcastRoomUpdate(room) {
  const snapshot = roomSnapshot(room);
  for (const playerId of room.players) {
    const player = players.get(playerId);
    if (!player) continue;
    safeSend(player.ws, { type: "room_update", room: snapshot });
  }
}

function broadcastChat(room, { fromId = null, fromName = "SYSTEM", message, system = false }) {
  const payload = {
    type: "chat",
    chat: {
      fromId,
      fromName,
      message,
      system,
      ts: Date.now(),
    },
  };

  for (const playerId of room.players) {
    const player = players.get(playerId);
    if (!player) continue;
    safeSend(player.ws, payload);
  }
}

function sendPrivate(playerId, message) {
  const player = players.get(playerId);
  if (!player) return;
  safeSend(player.ws, {
    type: "private_info",
    message,
  });
}

function resetVotes(room) {
  room.game.votes = {};
  room.game.lastExecutedId = null;
  room.game.lastVoteResult = null;
}

function assignRoles(room) {
  const memberIds = [...room.players.values()];
  if (memberIds.length < 3) {
    return false;
  }

  const mafiaId = memberIds[Math.floor(Math.random() * memberIds.length)];
  room.game.roles = {};
  room.game.mafiaId = mafiaId;
  room.game.phase = "morning";
  room.game.mafiaContinue = true;
  room.game.abilityUsed = {};
  resetVotes(room);

  for (const playerId of memberIds) {
    const role = playerId === mafiaId ? "mafia" : "citizen";
    room.game.roles[playerId] = role;
    const player = players.get(playerId);
    if (!player) continue;
    safeSend(player.ws, {
      type: "role_assigned",
      role,
      day: room.game.day,
    });
  }

  broadcastChat(room, {
    system: true,
    message: `${room.game.day}일차 아침입니다. 채팅과 능력 사용 후 투표를 시작하세요.`,
  });

  return true;
}

function finishGame(room, reason) {
  room.game.inProgress = false;
  room.game.phase = "ended";
  room.game.roles = {};
  room.game.mafiaId = null;
  room.game.mafiaContinue = true;
  room.game.abilityUsed = {};
  room.game.votes = {};
  broadcastChat(room, { system: true, message: `게임 종료: ${reason}` });
  broadcastRoomUpdate(room);
  broadcastRoomsList();
}

function handleVoteResolution(room) {
  const votes = Object.values(room.game.votes);
  if (votes.length === 0) {
    room.game.lastVoteResult = "기권";
    broadcastChat(room, { system: true, message: "투표가 모두 기권되어 마피아가 생존했습니다." });
  }

  const countMap = {};
  for (const targetId of votes) {
    if (!targetId) continue;
    countMap[targetId] = (countMap[targetId] || 0) + 1;
  }

  let maxCount = 0;
  let winners = [];
  for (const [targetId, count] of Object.entries(countMap)) {
    if (count > maxCount) {
      maxCount = count;
      winners = [targetId];
    } else if (count === maxCount) {
      winners.push(targetId);
    }
  }

  let executedId = null;
  if (winners.length === 1) {
    executedId = winners[0];
  }

  room.game.lastExecutedId = executedId;

  if (!executedId) {
    room.game.lastVoteResult = "동률 혹은 전원 기권";
    broadcastChat(room, { system: true, message: "동률/기권으로 처형자가 없습니다." });
  } else {
    const executedPlayer = players.get(executedId);
    room.game.lastVoteResult = `${executedPlayer?.name || executedId} 처형`;
    broadcastChat(room, { system: true, message: `${executedPlayer?.name || executedId}님이 처형되었습니다.` });
  }

  const mafiaId = room.game.mafiaId;
  if (executedId && executedId === mafiaId) {
    for (const playerId of room.players) {
      if (playerId !== mafiaId) {
        players.get(playerId).score += 10;
      }
    }
    broadcastChat(room, { system: true, message: "마피아 검거 성공! 시민 전원 +10점" });
    finishGame(room, "마피아 검거");
    return;
  }

  const mafiaPlayer = players.get(mafiaId);
  if (!mafiaPlayer) {
    finishGame(room, "마피아 연결 종료");
    return;
  }

  const aliveCitizens = Math.max(room.players.size - 1, 0);
  mafiaPlayer.score += aliveCitizens;
  broadcastChat(room, {
    system: true,
    message: `마피아 생존! ${mafiaPlayer.name} +${aliveCitizens}점 획득`,
  });

  if (!room.game.mafiaContinue) {
    finishGame(room, "마피아가 다음날 진행 중단 선택");
    return;
  }

  room.game.day += 1;
  assignRoles(room);
  broadcastRoomUpdate(room);
}

function ensureInRoom(player) {
  if (!player.roomId) {
    safeSend(player.ws, { type: "error", message: "먼저 방에 입장하세요." });
    return false;
  }
  return true;
}

function ensureHost(player, room) {
  if (room.hostId !== player.id) {
    safeSend(player.ws, { type: "error", message: "방장만 실행할 수 있습니다." });
    return false;
  }
  return true;
}

function ensureInGame(player, room) {
  if (!room.game.inProgress) {
    safeSend(player.ws, { type: "error", message: "게임이 진행 중이 아닙니다." });
    return false;
  }
  return true;
}

function ensureMafia(player, room) {
  if (room.game.mafiaId !== player.id) {
    safeSend(player.ws, { type: "error", message: "마피아만 사용할 수 있습니다." });
    return false;
  }
  return true;
}

function playerRole(room, playerId) {
  return room.game.roles[playerId] || "citizen";
}

function leaveRoom(player) {
  if (!player.roomId) return;
  const room = getRoom(player.roomId);
  if (!room) {
    player.roomId = null;
    return;
  }

  room.players.delete(player.id);

  if (room.hostId === player.id) {
    room.hostId = room.players.values().next().value || null;
  }

  if (room.players.size === 0) {
    rooms.delete(room.id);
  } else {
    if (room.game.inProgress && room.players.size < 3) {
      finishGame(room, "인원 부족으로 종료");
    } else {
      broadcastChat(room, { system: true, message: `${player.name}님이 방을 나갔습니다.` });
      broadcastRoomUpdate(room);
    }
  }

  player.roomId = null;
  broadcastRoomsList();
}

wss.on("connection", (ws) => {
  const playerId = randomId("p");
  const player = {
    id: playerId,
    name: `플레이어-${playerId.slice(-4)}`,
    score: 0,
    roomId: null,
    ws,
  };
  players.set(playerId, player);

  safeSend(ws, {
    type: "welcome",
    playerId,
    name: player.name,
  });
  sendRoomsList(player);

  ws.on("message", (raw) => {
    let packet;
    try {
      packet = JSON.parse(raw.toString());
    } catch {
      safeSend(ws, { type: "error", message: "잘못된 JSON 형식입니다." });
      return;
    }

    const type = packet.type;

    if (type === "set_name") {
      const name = String(packet.name || "").trim();
      if (!name) {
        safeSend(ws, { type: "error", message: "이름은 비어 있을 수 없습니다." });
        return;
      }
      player.name = name.slice(0, 20);
      safeSend(ws, { type: "name_set", name: player.name });
      if (player.roomId) {
        const room = getRoom(player.roomId);
        if (room) {
          broadcastRoomUpdate(room);
        }
      }
      broadcastRoomsList();
      return;
    }

    if (type === "list_rooms") {
      sendRoomsList(player);
      return;
    }

    if (type === "create_room") {
      const custom = String(packet.roomId || "").trim();
      const roomId = custom || randomId("room").slice(0, 10).toUpperCase();
      if (rooms.has(roomId)) {
        safeSend(ws, { type: "error", message: "이미 존재하는 방 코드입니다." });
        return;
      }
      leaveRoom(player);
      const room = {
        id: roomId,
        hostId: player.id,
        players: new Set([player.id]),
        game: {
          inProgress: false,
          day: 0,
          phase: "lobby",
          roles: {},
          mafiaId: null,
          votes: {},
          mafiaContinue: true,
          abilityUsed: {},
          lastExecutedId: null,
          lastVoteResult: null,
        },
      };
      rooms.set(roomId, room);
      player.roomId = roomId;
      broadcastRoomUpdate(room);
      broadcastChat(room, { system: true, message: `${player.name}님이 방을 만들었습니다.` });
      broadcastRoomsList();
      return;
    }

    if (type === "join_room") {
      const roomId = String(packet.roomId || "").trim();
      const room = getRoom(roomId);
      if (!room) {
        safeSend(ws, { type: "error", message: "방을 찾을 수 없습니다." });
        return;
      }
      if (room.game.inProgress) {
        safeSend(ws, { type: "error", message: "진행 중인 게임에는 입장할 수 없습니다." });
        return;
      }
      leaveRoom(player);
      room.players.add(player.id);
      player.roomId = room.id;
      broadcastRoomUpdate(room);
      broadcastChat(room, { system: true, message: `${player.name}님이 입장했습니다.` });
      broadcastRoomsList();
      return;
    }

    if (type === "leave_room") {
      leaveRoom(player);
      safeSend(ws, { type: "left_room" });
      return;
    }

    if (type === "start_game") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureHost(player, room)) return;
      if (room.players.size < 3) {
        safeSend(ws, { type: "error", message: "최소 3명이 필요합니다." });
        return;
      }

      room.game.inProgress = true;
      room.game.day = 1;
      room.game.phase = "morning";
      const ok = assignRoles(room);
      if (!ok) {
        finishGame(room, "인원 부족");
        return;
      }
      broadcastRoomUpdate(room);
      broadcastRoomsList();
      return;
    }

    if (type === "start_voting") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureHost(player, room) || !ensureInGame(player, room)) return;

      room.game.phase = "voting";
      resetVotes(room);
      broadcastChat(room, { system: true, message: "처형 투표를 시작합니다. 각자 투표하세요." });
      broadcastRoomUpdate(room);
      return;
    }

    if (type === "set_vote") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureInGame(player, room)) return;
      if (room.game.phase !== "voting") {
        safeSend(ws, { type: "error", message: "현재 투표 단계가 아닙니다." });
        return;
      }

      const targetId = packet.targetId ? String(packet.targetId) : null;
      if (targetId && !room.players.has(targetId)) {
        safeSend(ws, { type: "error", message: "유효하지 않은 투표 대상입니다." });
        return;
      }

      room.game.votes[player.id] = targetId;
      broadcastRoomUpdate(room);
      return;
    }

    if (type === "close_voting") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureHost(player, room) || !ensureInGame(player, room)) return;
      if (room.game.phase !== "voting") {
        safeSend(ws, { type: "error", message: "현재 투표 단계가 아닙니다." });
        return;
      }

      handleVoteResolution(room);
      broadcastRoomUpdate(room);
      return;
    }

    if (type === "mafia_continue") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureInGame(player, room) || !ensureMafia(player, room)) return;
      if (room.game.phase !== "voting") {
        safeSend(ws, { type: "error", message: "투표 단계에서만 결정할 수 있습니다." });
        return;
      }

      const continueGame = Boolean(packet.continueGame);
      room.game.mafiaContinue = continueGame;
      sendPrivate(player.id, continueGame ? "다음 날 진행: 계속" : "다음 날 진행: 중단");
      return;
    }

    if (type === "use_ability") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureInGame(player, room)) return;

      const phase = room.game.phase;
      if (phase !== "morning") {
        safeSend(ws, { type: "error", message: "능력은 아침 단계에서만 사용할 수 있습니다." });
        return;
      }

      if (room.game.abilityUsed[player.id]) {
        safeSend(ws, { type: "error", message: "이번 턴에는 이미 능력을 사용했습니다." });
        return;
      }

      const role = playerRole(room, player.id);
      const ability = String(packet.ability || "");

      if (role === "citizen" && ability === "inspect") {
        const targetId = String(packet.targetId || "");
        if (!room.players.has(targetId)) {
          safeSend(ws, { type: "error", message: "대상을 찾을 수 없습니다." });
          return;
        }
        const isMafia = targetId === room.game.mafiaId;
        const targetName = players.get(targetId)?.name || targetId;
        sendPrivate(player.id, `${targetName}님의 이번 턴 역할: ${isMafia ? "마피아" : "시민"}`);
        room.game.abilityUsed[player.id] = true;
        return;
      }

      if (role === "mafia" && ability === "mislead") {
        const text = String(packet.text || "").trim().slice(0, 80);
        if (!text) {
          safeSend(ws, { type: "error", message: "메시지를 입력하세요." });
          return;
        }
        broadcastChat(room, {
          system: true,
          message: `[익명 제보] ${text}`,
        });
        room.game.abilityUsed[player.id] = true;
        return;
      }

      safeSend(ws, { type: "error", message: "현재 역할에서 사용할 수 없는 능력입니다." });
      return;
    }

    if (type === "send_chat") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room) return;
      const text = String(packet.message || "").trim().slice(0, 200);
      if (!text) return;
      broadcastChat(room, {
        fromId: player.id,
        fromName: player.name,
        message: text,
        system: false,
      });
      return;
    }

    safeSend(ws, { type: "error", message: `지원하지 않는 타입: ${type}` });
  });

  ws.on("close", () => {
    leaveRoom(player);
    players.delete(player.id);
  });

  ws.on("error", () => {
    leaveRoom(player);
    players.delete(player.id);
  });
});

server.listen(PORT, () => {
  console.log(`Game server listening on http://0.0.0.0:${PORT}`);
});
