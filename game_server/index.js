const express = require("express");
const cors = require("cors");
const http = require("http");
const { WebSocketServer } = require("ws");
const dgram = require("dgram");
const os = require("os");

const app = express();
app.use(cors());
app.use(express.json());

app.get("/health", (_, res) => {
  res.json({ ok: true, now: new Date().toISOString(), rulesVersion: RULES_VERSION });
});

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = Number(process.env.PORT || 8080);
const DISCOVERY_PORT = Number(process.env.DISCOVERY_PORT || 41234);
const DISCOVERY_MAGIC = "GUILNOCENT_DISCOVER";
const MAX_ROOM_PLAYERS = 12;
const ALLOWED_EMOJIS = new Set(["😀", "😂", "😱", "🤔", "😡", "😭", "👍", "👎", "🙏", "👏"]);
const MODE_ORIGINAL = "original";
const MODE_MORAL_ROULETTE = "moral_roulette";
const RULES_VERSION = "2026.03.06-rules-1";
const PRIVATE_DANGER_PREFIX = "[!DANGER!] ";

function defaultRoleCounts(mode) {
  if (mode === MODE_ORIGINAL) {
    return { mafia: 1, doctor: 1, police: 1, joker: 0 };
  }
  return { mafia: 1, doctor: 1, police: 1, joker: 1 };
}

function defaultScoreSettings() {
  return {
    mafiaJoker2Plus: 2,
    mafiaJoker1: 4,
    mafiaJoker0: 6,
    citizenEndMultiplier: 2,
  };
}

function normalizeScoreSettings(input) {
  const defaults = defaultScoreSettings();
  const parse = (value, fallback) => {
    const num = Number(value);
    if (!Number.isFinite(num)) return fallback;
    return Math.max(0, Math.min(99, Math.floor(num)));
  };
  return {
    mafiaJoker2Plus: parse(input?.mafiaJoker2Plus, defaults.mafiaJoker2Plus),
    mafiaJoker1: parse(input?.mafiaJoker1, defaults.mafiaJoker1),
    mafiaJoker0: parse(input?.mafiaJoker0, defaults.mafiaJoker0),
    citizenEndMultiplier: parse(input?.citizenEndMultiplier, defaults.citizenEndMultiplier),
  };
}

function moralRouletteJokerCountForAlive(aliveCount) {
  if (aliveCount >= 11) return 3;
  if (aliveCount >= 9) return 2;
  if (aliveCount >= 7) return 1;
  return 0;
}

function moralRouletteMafiaCountForAlive(room, aliveCount) {
  if (aliveCount <= 0) return 0;
  if (room.game.moralRouletteTwoMafiaMode && !room.game.moralRouletteForcedSingleMafia && aliveCount >= 2) {
    return 2;
  }
  return 1;
}

function effectiveRoleCounts(room, aliveCount) {
  if (room.game.mode === MODE_MORAL_ROULETTE) {
    return {
      mafia: moralRouletteMafiaCountForAlive(room, aliveCount),
      doctor: aliveCount >= 2 ? 1 : 0,
      police: aliveCount >= 3 ? 1 : 0,
      joker: moralRouletteJokerCountForAlive(aliveCount),
    };
  }
  return normalizeRoleCounts(room.game.mode, room.game.roleCounts);
}

function getLanIpv4() {
  const forcedLanIp = String(process.env.LAN_IP || "").trim();
  if (forcedLanIp) {
    return forcedLanIp;
  }

  const isPrivateIpv4 = (ip) => {
    return ip.startsWith("10.") || ip.startsWith("192.168.") || /^172\.(1[6-9]|2\d|3[0-1])\./.test(ip);
  };

  const interfaces = os.networkInterfaces();
  const privateCandidates = [];
  const fallbackCandidates = [];

  for (const list of Object.values(interfaces)) {
    if (!list) continue;
    for (const addressInfo of list) {
      if (addressInfo.family === "IPv4" && !addressInfo.internal) {
        if (isPrivateIpv4(addressInfo.address)) {
          privateCandidates.push(addressInfo.address);
        } else {
          fallbackCandidates.push(addressInfo.address);
        }
      }
    }
  }

  if (privateCandidates.length > 0) {
    return privateCandidates[0];
  }
  if (fallbackCandidates.length > 0) {
    return fallbackCandidates[0];
  }

  return null;
}

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
      phaseEndsAt: game.phaseEndsAt,
      phaseDurationSec: game.phaseDurationSec,
      votes: game.votes,
      mafiaContinue: game.mafiaContinue,
      mode: game.mode,
      scoreSettings: game.scoreSettings,
      roleCounts: effectiveRoleCounts(room, playerList.length),
      executionCandidateId: game.executionCandidateId,
      executionVotes: game.executionVotes,
      lastExecutedId: game.lastExecutedId,
      lastVoteResult: game.lastVoteResult,
      eliminatedIds: Object.keys(game.eliminatedIds || {}),
      canStart: (() => {
        const normalized = effectiveRoleCounts(room, playerList.length);
        const total = normalized.mafia + normalized.doctor + normalized.police + normalized.joker;
        return playerList.length >= 3 && total <= playerList.length;
      })(),
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

function broadcastChat(room, { fromId = null, fromName = "SYSTEM", message, system = false, centerNotice = false, isEmoji = false, imageAsset = null, highlightDanger = false }) {
  const payload = {
    type: "chat",
    chat: {
      fromId,
      fromName,
      message,
      system,
      centerNotice,
      isEmoji,
      imageAsset,
      highlightDanger,
      ts: Date.now(),
    },
  };

  for (const playerId of room.players) {
    const player = players.get(playerId);
    if (!player) continue;
    safeSend(player.ws, payload);
  }
}

function broadcastChatTo(room, playerIds, { fromId = null, fromName = "SYSTEM", message, system = false, centerNotice = false, isEmoji = false, imageAsset = null, highlightDanger = false }) {
  const payload = {
    type: "chat",
    chat: {
      fromId,
      fromName,
      message,
      system,
      centerNotice,
      isEmoji,
      imageAsset,
      highlightDanger,
      ts: Date.now(),
    },
  };

  for (const playerId of playerIds) {
    const player = players.get(playerId);
    if (!player) continue;
    safeSend(player.ws, payload);
  }
}

function sendPrivate(playerId, message, day = null, options = {}) {
  const player = players.get(playerId);
  if (!player) return;
  const payloadMessage = options.danger ? `${PRIVATE_DANGER_PREFIX}${message}` : message;
  safeSend(player.ws, {
    type: "ability_log",
    message: payloadMessage,
    day,
  });
}

function sendPrivateSystemChat(playerId, { message, imageAsset = null, highlightDanger = false }) {
  const player = players.get(playerId);
  if (!player) return;
  safeSend(player.ws, {
    type: "chat",
    chat: {
      fromId: null,
      fromName: "SYSTEM",
      message,
      system: true,
      centerNotice: false,
      isEmoji: false,
      imageAsset,
      highlightDanger,
      ts: Date.now(),
    },
  });
}

function clearRoomTimer(room) {
  if (room.game.phaseTimer) {
    clearTimeout(room.game.phaseTimer);
    room.game.phaseTimer = null;
  }
  room.game.phaseEndsAt = null;
  room.game.phaseDurationSec = null;
}

function setRoomTimer(room, durationSec, onTimeout) {
  clearRoomTimer(room);
  room.game.phaseDurationSec = durationSec;
  room.game.phaseEndsAt = Date.now() + durationSec * 1000;
  room.game.phaseTimer = setTimeout(() => {
    room.game.phaseTimer = null;
    room.game.phaseEndsAt = null;
    room.game.phaseDurationSec = null;
    onTimeout();
  }, durationSec * 1000);
}

function resetVotes(room) {
  room.game.votes = {};
  room.game.executionVotes = {};
  room.game.executionCandidateId = null;
  room.game.lastExecutedId = null;
  room.game.lastVoteResult = null;
}

function resetAbilityState(room) {
  room.game.abilityUsed = {};
  room.game.pendingKillTargetId = null;
  room.game.pendingHealTargetId = null;
}

function canUseSelfHeal(room, playerId, targetId) {
  if (targetId !== playerId) {
    return true;
  }
  const tracking = room.game.lastSelfHealDayByPlayer || {};
  const lastDay = tracking[playerId];
  if (typeof lastDay !== "number") {
    return true;
  }
  return room.game.day - lastDay > 1;
}

function markSelfHealIfNeeded(room, playerId, targetId) {
  if (targetId === playerId) {
    room.game.lastSelfHealDayByPlayer = room.game.lastSelfHealDayByPlayer || {};
    room.game.lastSelfHealDayByPlayer[playerId] = room.game.day;
  }
}

function apparentRoleOf(room, playerId) {
  const role = room.game.roles[playerId];
  if (role !== "joker") {
    return role || "citizen";
  }
  return room.game.jokerMaskRoles[playerId] || "citizen";
}

function shuffleInPlace(list) {
  for (let i = list.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [list[i], list[j]] = [list[j], list[i]];
  }
  return list;
}

function normalizeRoleCounts(mode, inputCounts) {
  const safe = {
    mafia: Number(inputCounts?.mafia || 0),
    doctor: Number(inputCounts?.doctor || 0),
    police: Number(inputCounts?.police || 0),
    joker: Number(inputCounts?.joker || 0),
  };
  safe.mafia = Math.max(1, Math.min(MAX_ROOM_PLAYERS, Math.floor(safe.mafia)));
  safe.doctor = Math.max(0, Math.min(MAX_ROOM_PLAYERS, Math.floor(safe.doctor)));
  safe.police = Math.max(0, Math.min(MAX_ROOM_PLAYERS, Math.floor(safe.police)));
  safe.joker = Math.max(0, Math.min(MAX_ROOM_PLAYERS, Math.floor(safe.joker)));
  if (mode === MODE_ORIGINAL) {
    safe.joker = 0;
  }
  return safe;
}

function rolePoolForDay(room, aliveCount) {
  const configured = effectiveRoleCounts(room, aliveCount);
  const pool = [];

  for (let i = 0; i < configured.mafia; i += 1) pool.push("mafia");
  for (let i = 0; i < configured.doctor; i += 1) pool.push("doctor");
  for (let i = 0; i < configured.police; i += 1) pool.push("police");
  for (let i = 0; i < configured.joker; i += 1) pool.push("joker");

  while (pool.length > aliveCount) {
    const jokerIdx = pool.lastIndexOf("joker");
    if (jokerIdx >= 0) {
      pool.splice(jokerIdx, 1);
      continue;
    }
    const policeIdx = pool.lastIndexOf("police");
    if (policeIdx >= 0) {
      pool.splice(policeIdx, 1);
      continue;
    }
    const doctorIdx = pool.lastIndexOf("doctor");
    if (doctorIdx >= 0) {
      pool.splice(doctorIdx, 1);
      continue;
    }
    const mafiaCount = pool.filter((role) => role === "mafia").length;
    if (mafiaCount > 1) {
      const mafiaIdx = pool.lastIndexOf("mafia");
      pool.splice(mafiaIdx, 1);
      continue;
    }
    break;
  }

  if (!pool.includes("mafia") && aliveCount > 0) {
    pool.push("mafia");
  }
  while (pool.length > aliveCount) {
    const idx = pool.findIndex((role) => role !== "mafia");
    if (idx < 0) break;
    pool.splice(idx, 1);
  }
  return pool;
}

function moralRouletteMafiaSurvivalScore(room) {
  const settings = normalizeScoreSettings(room.game.scoreSettings || {});
  const jokerCount = moralRouletteJokerCountForAlive(alivePlayerIds(room).length);
  if (jokerCount >= 2) return settings.mafiaJoker2Plus;
  if (jokerCount === 1) return settings.mafiaJoker1;
  return settings.mafiaJoker0;
}

function markMoralRouletteMafiaDeath(room, eliminatedPlayerId) {
  if (room.game.mode !== MODE_MORAL_ROULETTE) return;
  if (!room.game.moralRouletteTwoMafiaMode || room.game.moralRouletteForcedSingleMafia) return;
  if (playerRole(room, eliminatedPlayerId) !== "mafia") return;
  room.game.moralRouletteForcedSingleMafia = true;
  broadcastChat(room, {
    system: true,
    message: "마피아 1명이 탈락하여 다음 턴부터 마피아는 1명만 배정됩니다.",
  });

  const assignedMafiaIds = room.game.assignedMafiaIds || [];
  const aliveAssignedMafia = assignedMafiaIds.filter((playerId) => !isEliminated(room, playerId));
  if (assignedMafiaIds.length >= 2 && aliveAssignedMafia.length === 1) {
    room.game.skipMafiaSurvivalScoreThisTurn = true;
    room.game.forceMafiaContinueThisTurn = true;
    room.game.preservedMafiaPlayerId = aliveAssignedMafia[0];
    room.game.preservedMafiaTurns = 1;
    room.game.lastMafiaSurvivalGainByPlayer = {};
    broadcastChat(room, {
      system: true,
      message: "이번 턴은 마피아 생존 점수가 지급되지 않으며, 남은 마피아는 1턴 더 마피아 역할을 유지하고 자동 진행됩니다.",
    });
  }
}

function moralRouletteCitizenEndScore(room, reason, day) {
  const safeDay = Math.max(Number(day) || 0, 0);
  if (safeDay <= 0) return 0;
  if (String(reason || "") === "마피아 승리") {
    return safeDay;
  }
  const settings = normalizeScoreSettings(room.game.scoreSettings || {});
  return safeDay * settings.citizenEndMultiplier;
}

function awardMoralRouletteCitizenAdvantageBonus(room) {
  if (room.game.mode !== MODE_MORAL_ROULETTE) return;
  return;
}

function applyMafiaStopPenalty(room) {
  if (room.game.mode !== MODE_MORAL_ROULETTE) return;
  const votes = room.game.mafiaDecisionVotes || {};
  const gains = room.game.lastMafiaSurvivalGainByPlayer || {};
  const names = [];

  for (const [playerId, decision] of Object.entries(votes)) {
    if (decision !== false) continue;
    const player = players.get(playerId);
    if (!player) continue;
    const gained = Number(gains[playerId] || 0);
    if (gained <= 0) continue;
    const kept = Math.floor(gained / 2);
    const penalty = gained - kept;
    if (penalty <= 0) continue;
    player.score -= penalty;
    names.push(player.name);
  }

  if (names.length > 0) {
    broadcastChat(room, {
      system: true,
      message: `스톱 선택자 점수 반감 적용: ${names.join(", ")}`,
    });
  }
}

function resolveMafiaDecisionVotes(room, reason = null) {
  if (!room.game.inProgress) return;
  if (room.game.phase !== "mafia_decision") return;

  const aliveMafia = aliveMafiaIds(room);
  if (aliveMafia.length === 0) {
    finishGame(room, "마피아 전원 제거");
    return;
  }

  const votes = room.game.mafiaDecisionVotes || {};
  let stopCount = 0;
  let continueCount = 0;

  for (const mafiaId of aliveMafia) {
    const vote = votes[mafiaId];
    if (vote === false) {
      stopCount += 1;
    } else {
      continueCount += 1;
    }
  }

  const shouldContinue = continueCount >= stopCount;
  room.game.mafiaContinue = shouldContinue;

  if (reason) {
    broadcastChat(room, {
      system: true,
      message: reason,
    });
  }

  if (!shouldContinue) {
    applyMafiaStopPenalty(room);
    finishGame(room, "마피아 스톱 선택");
    return;
  }

  room.game.forceMafiaContinueThisTurn = false;
  room.game.skipMafiaSurvivalScoreThisTurn = false;

  advanceToNextDay(room);
}

function tryAwardMoralRouletteOneVsOneBonus(room, previousAliveCount) {
  if (room.game.mode !== MODE_MORAL_ROULETTE) return;
  if (room.game.oneVsOneBonusAwarded) return;
  if (previousAliveCount !== 3) return;

  const aliveIds = alivePlayerIds(room);
  if (aliveIds.length !== 2) return;

  const aliveMafiaIdsNow = aliveIds.filter((playerId) => playerRole(room, playerId) === "mafia");
  if (aliveMafiaIdsNow.length !== 1) return;

  const mafiaPlayer = players.get(aliveMafiaIdsNow[0]);
  if (!mafiaPlayer) return;

  mafiaPlayer.score += 10;
  room.game.oneVsOneBonusAwarded = true;
  broadcastChat(room, {
    system: true,
    message: `1대1 구도 달성! 마피아 ${mafiaPlayer.name} +10점 획득`,
  });
  finishGame(room, "마피아 승리");
  return true;
}

function aliveMafiaIds(room) {
  return alivePlayerIds(room).filter((playerId) => playerRole(room, playerId) === "mafia");
}

function checkOriginalVictory(room) {
  if (room.game.mode !== MODE_ORIGINAL) return false;
  const aliveIds = alivePlayerIds(room);
  const mafiaCount = aliveIds.filter((playerId) => playerRole(room, playerId) === "mafia").length;
  const citizenCount = aliveIds.length - mafiaCount;

  if (mafiaCount === 0) {
    broadcastChat(room, { system: true, message: "승리 조건 달성: 모든 마피아가 제거되어 시민 승리입니다." });
    finishGame(room, "시민 승리");
    return true;
  }
  if (mafiaCount > citizenCount) {
    broadcastChat(room, { system: true, message: "승리 조건 달성: 마피아 수가 시민 수를 초과해 마피아 승리입니다." });
    finishGame(room, "마피아 승리");
    return true;
  }
  return false;
}

function isEliminated(room, playerId) {
  return Boolean(room.game.eliminatedIds && room.game.eliminatedIds[playerId]);
}

function alivePlayerIds(room) {
  return [...room.players].filter((playerId) => !isEliminated(room, playerId));
}

function roleLabelForSummary(role) {
  if (role === "mafia") return "마피아";
  if (role === "doctor") return "의사";
  if (role === "police") return "경찰";
  if (role === "joker") return "조커";
  return "시민";
}

function scoreSummaryLines(room, finalRoles = {}) {
  const list = [...room.players]
    .map((playerId) => players.get(playerId))
    .filter(Boolean)
    .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));

  if (list.length === 0) {
    return [];
  }

  return list.map((player, index) => {
    const role = finalRoles[player.id] || "citizen";
    return `${index + 1}. ${player.name} (${roleLabelForSummary(role)}) - ${player.score}점`;
  });
}

function assignRoles(room) {
  const memberIds = alivePlayerIds(room);
  if (memberIds.length < 3) {
    return false;
  }

  const shuffled = shuffleInPlace([...memberIds]);
  const rolePool = shuffleInPlace(rolePoolForDay(room, shuffled.length));

  room.game.roles = {};
  room.game.mafiaId = null;
  room.game.policeId = null;
  room.game.doctorId = null;
  room.game.jokerMaskRoles = {};
  room.game.phase = "ability";
  room.game.mafiaDecisionVotes = {};
  room.game.lastMafiaSurvivalGainByPlayer = {};
  room.game.skipMafiaSurvivalScoreThisTurn = false;
  room.game.forceMafiaContinueThisTurn = false;
  room.game.assignedMafiaIds = [];
  resetAbilityState(room);
  resetVotes(room);

  let forcedMafiaId = null;
  if (
    room.game.mode === MODE_MORAL_ROULETTE &&
    room.game.preservedMafiaTurns > 0 &&
    typeof room.game.preservedMafiaPlayerId === "string" &&
    memberIds.includes(room.game.preservedMafiaPlayerId)
  ) {
    forcedMafiaId = room.game.preservedMafiaPlayerId;
    const mafiaIdx = rolePool.indexOf("mafia");
    if (mafiaIdx >= 0) {
      rolePool.splice(mafiaIdx, 1);
    }
  } else {
    room.game.preservedMafiaPlayerId = null;
    room.game.preservedMafiaTurns = 0;
  }

  for (const playerId of memberIds) {
    const role = forcedMafiaId === playerId ? "mafia" : (rolePool.pop() || "citizen");
    if (role === "mafia" && !room.game.mafiaId) {
      room.game.mafiaId = playerId;
    }
    if (role === "mafia") {
      room.game.assignedMafiaIds.push(playerId);
    }
    if (role === "doctor" && !room.game.doctorId) {
      room.game.doctorId = playerId;
    }
    if (role === "police" && !room.game.policeId) {
      room.game.policeId = playerId;
    }
    if (role === "joker") {
      const masks = ["mafia", "doctor", "police"];
      room.game.jokerMaskRoles[playerId] = masks[Math.floor(Math.random() * masks.length)];
    }
    room.game.roles[playerId] = role;
  }

  for (const playerId of memberIds) {
    const role = room.game.roles[playerId] || "citizen";
    const player = players.get(playerId);
    if (!player) continue;
    const fakeRole = role === "joker" ? room.game.jokerMaskRoles[playerId] : null;
    const mafiaPeerIds = role === "mafia"
      ? room.game.assignedMafiaIds.filter((id) => id !== playerId)
      : [];
    safeSend(player.ws, {
      type: "role_assigned",
      role,
      fakeRole,
      day: room.game.day,
      mafiaPeerIds,
    });
  }

  if (forcedMafiaId) {
    room.game.preservedMafiaTurns = Math.max((room.game.preservedMafiaTurns || 0) - 1, 0);
    if (room.game.preservedMafiaTurns <= 0) {
      room.game.preservedMafiaPlayerId = null;
    }
  }

  return true;
}

function resolveNightAbilities(room) {
  const killTargetId = room.game.pendingKillTargetId;
  const healTargetId = room.game.pendingHealTargetId;

  if (!killTargetId) {
    broadcastChat(room, {
      system: true,
      message: "밤 능력 결과: 마피아의 탈락 대상이 선택되지 않았습니다.",
    });
    return;
  }

  const targetName = players.get(killTargetId)?.name || killTargetId;
  if (healTargetId && healTargetId === killTargetId) {
    broadcastChat(room, {
      system: true,
      message: "",
      imageAsset: "doctor_success.png",
    });
    broadcastChat(room, {
      system: true,
      message: `밤 능력 결과: ${targetName}님이 의사의 치료로 생존했습니다.`,
    });
    return;
  }

  room.game.eliminatedIds[killTargetId] = true;
  markMoralRouletteMafiaDeath(room, killTargetId);
  broadcastChat(room, {
    system: true,
    message: "",
    imageAsset: "mafia.png",
  });
  broadcastChat(room, {
    system: true,
    message: `밤 능력 결과: ${targetName}님이 탈락했습니다.`,
  });
}

function startMafiaDecisionPhase(room) {
  const mafiaIds = aliveMafiaIds(room);
  if (mafiaIds.length === 0) {
    finishGame(room, "마피아 연결 종료");
    return;
  }

  room.game.phase = "mafia_decision";
  room.game.mafiaContinue = null;
  room.game.mafiaDecisionVotes = {};
  const names = mafiaIds
    .map((playerId) => players.get(playerId)?.name || playerId)
    .join(", ");

  if (room.game.forceMafiaContinueThisTurn) {
    for (const mafiaId of mafiaIds) {
      room.game.mafiaDecisionVotes[mafiaId] = true;
    }
    broadcastChat(room, {
      system: true,
      message: `마피아(${names}) 진행 선택: 이번 턴은 규칙에 의해 자동으로 계속 진행됩니다.`,
    });
    setRoomTimer(room, 3, () => {
      resolveMafiaDecisionVotes(room, "자동 계속 진행 처리");
    });
    broadcastRoomUpdate(room);
    broadcastRoomsList();
    return;
  }


  if (room.game.mode === MODE_MORAL_ROULETTE) {
    broadcastChat(room, {
      system: true,
      message: "계속 진행 : 점수 추가 획득, 중지 : 점수 손실",
    });
  }

  broadcastChat(room, {
    system: true,
    message: `마피아(${names})는 다음 날 진행 여부를 투표하세요: 계속 진행 / 스톱 (20초)`,
  });
  setRoomTimer(room, 20, () => {
    resolveMafiaDecisionVotes(room, "시간 초과: 미투표는 계속 진행으로 처리됩니다.");
  });
  broadcastRoomUpdate(room);
  broadcastRoomsList();
}

function advanceToNextDay(room) {
  room.game.day += 1;

  if (room.game.mode === MODE_MORAL_ROULETTE) {
    const ok = assignRoles(room);
    if (!ok) {
      finishGame(room, "인원 부족");
      return;
    }
  } else {
    resetAbilityState(room);
    resetVotes(room);
  }

  room.game.phase = "ability";
  broadcastChat(room, {
    system: true,
    message: room.game.mode === MODE_MORAL_ROULETTE
      ? `${room.game.day}일차 밤입니다. 새 직업이 배정되었습니다. 능력 사용 대상을 선택하세요. (30초)`
      : `${room.game.day}일차 밤입니다. 기존 직업을 유지한 채 능력 사용 대상을 선택하세요. (30초)`,
  });
  setRoomTimer(room, 30, () => {
    startVotingPhase(room);
  });
  broadcastRoomUpdate(room);
  broadcastRoomsList();
}

function continueAfterExecution(room) {
  if (room.game.mode === MODE_MORAL_ROULETTE) {
    const mafiaIds = aliveMafiaIds(room);
    if (mafiaIds.length === 0) {
      broadcastChat(room, { system: true, message: "마피아 전원이 제거되었습니다." });
      finishGame(room, "마피아 검거");
      return;
    }

    awardMoralRouletteCitizenAdvantageBonus(room);

    const gain = moralRouletteMafiaSurvivalScore(room);
    room.game.lastMafiaSurvivalGainByPlayer = {};
    const mafiaNames = mafiaIds.map((playerId) => players.get(playerId)?.name || playerId).join(", ");

    if (room.game.skipMafiaSurvivalScoreThisTurn) {
      broadcastChat(room, {
        system: true,
        message: `이번 턴은 특수 규칙으로 마피아(${mafiaNames}) 생존 점수가 지급되지 않습니다.`,
      });
    } else {
      for (const mafiaId of mafiaIds) {
        const mafiaPlayer = players.get(mafiaId);
        if (!mafiaPlayer) continue;
        mafiaPlayer.score += gain;
        room.game.lastMafiaSurvivalGainByPlayer[mafiaId] = gain;
      }
      broadcastChat(room, {
        system: true,
        message: `마피아 생존! ${mafiaNames} 각각 +${gain}점 획득`,
      });
    }
    startMafiaDecisionPhase(room);
    return;
  }

  if (checkOriginalVictory(room)) {
    return;
  }

  advanceToNextDay(room);
}

function resolveExecutionApproval(room) {
  const aliveBeforeExecution = alivePlayerIds(room).length;
  const candidateId = room.game.executionCandidateId;
  if (!candidateId) {
    room.game.lastVoteResult = "처형 후보 없음";
    broadcastChat(room, { system: true, message: "처형 후보가 없어 다음 단계로 진행합니다." });
    if (tryAwardMoralRouletteOneVsOneBonus(room, aliveBeforeExecution)) {
      return;
    }
    continueAfterExecution(room);
    return;
  }

  const aliveIds = alivePlayerIds(room);
  let approve = 0;
  let reject = 0;
  for (const playerId of aliveIds) {
    const vote = room.game.executionVotes[playerId];
    if (vote === true) approve += 1;
    if (vote === false) reject += 1;
  }

  const majority = Math.floor(aliveIds.length / 2) + 1;
  const candidateName = players.get(candidateId)?.name || candidateId;

  if (approve >= majority) {
    const eliminatedRole = playerRole(room, candidateId);
    room.game.eliminatedIds[candidateId] = true;
    if (eliminatedRole === "mafia") {
      markMoralRouletteMafiaDeath(room, candidateId);
    }
    room.game.lastExecutedId = candidateId;
    room.game.lastVoteResult = `${candidateName} 처형 확정`;
    broadcastChat(room, { system: true, message: `찬성 ${approve}표로 ${candidateName}님이 처형되었습니다.` });

    if (room.game.mode === MODE_ORIGINAL && checkOriginalVictory(room)) {
      return;
    }

    if (tryAwardMoralRouletteOneVsOneBonus(room, aliveBeforeExecution)) {
      return;
    }
    continueAfterExecution(room);
    return;
  }

  if (reject >= majority) {
    room.game.lastExecutedId = null;
    room.game.lastVoteResult = `${candidateName} 생존`;
    broadcastChat(room, { system: true, message: `반대 ${reject}표로 ${candidateName}님은 생존했습니다.` });
    if (tryAwardMoralRouletteOneVsOneBonus(room, aliveBeforeExecution)) {
      return;
    }
    continueAfterExecution(room);
    return;
  }

  room.game.lastExecutedId = null;
  room.game.lastVoteResult = `${candidateName} 찬반 과반 미달`;
  broadcastChat(room, {
    system: true,
    message: `찬반 투표 과반 미달(찬성 ${approve}, 반대 ${reject})로 ${candidateName}님은 생존합니다.`,
  });
  if (tryAwardMoralRouletteOneVsOneBonus(room, aliveBeforeExecution)) {
    return;
  }
  continueAfterExecution(room);
}

function startExecutionVotePhase(room, candidateId) {
  room.game.phase = "execution_vote";
  room.game.executionCandidateId = candidateId;
  room.game.executionVotes = {};
  const candidateName = players.get(candidateId)?.name || candidateId;
  broadcastChat(room, {
    system: true,
    message: `처형 찬반 투표: ${candidateName}님을 처형할까요? (30초)` ,
  });
  setRoomTimer(room, 30, () => {
    resolveExecutionApproval(room);
  });
  broadcastRoomUpdate(room);
}

function resolveVotingAndAdvance(room) {
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

  let candidateId = null;
  if (winners.length === 1) {
    candidateId = winners[0];
  }

  room.game.lastExecutedId = null;

  if (!candidateId) {
    room.game.lastVoteResult = "동률 혹은 전원 기권";
    broadcastChat(room, { system: true, message: "동률/기권으로 처형자가 없습니다." });
    continueAfterExecution(room);
    return;
  }

  const candidateName = players.get(candidateId)?.name || candidateId;
  room.game.lastVoteResult = `처형 후보: ${candidateName}`;
  broadcastChat(room, {
    system: true,
    message: "",
    imageAsset: "execution.png",
  });
  broadcastChat(room, {
    system: true,
    message: `처형 투표 결과 ${candidateName}님이 후보로 선정되었습니다. 찬반 투표를 진행합니다.`,
  });
  startExecutionVotePhase(room, candidateId);
}

function handleMafiaDecision(room, shouldContinue, reason = null) {
  resolveMafiaDecisionVotes(room, reason);
}

function startVotingPhase(room) {
  const aliveBeforeNightResolution = alivePlayerIds(room).length;
  resolveNightAbilities(room);
  if (tryAwardMoralRouletteOneVsOneBonus(room, aliveBeforeNightResolution)) {
    return;
  }
  if (checkOriginalVictory(room)) {
    return;
  }
  room.game.phase = "voting";
  resetVotes(room);
  broadcastChat(room, {
    system: true,
    message: `${room.game.day}일차 아침이 시작되었습니다. 투표 대상을 선택하세요. (180초)`,
  });
  setRoomTimer(room, 180, () => {
    resolveVotingAndAdvance(room);
  });
  broadcastRoomUpdate(room);
}

function finishGame(room, reason) {
  const finalRoles = { ...(room.game.roles || {}) };
  const finalEliminatedIds = { ...(room.game.eliminatedIds || {}) };
  const finalDay = room.game.day;

  if (room.game.mode === MODE_MORAL_ROULETTE) {
    const gain = moralRouletteCitizenEndScore(room, reason, finalDay);
    if (gain > 0) {
      for (const playerId of room.players) {
        if (finalEliminatedIds[playerId]) continue;
        const role = finalRoles[playerId] || "citizen";
        if (role === "mafia") continue;
        const player = players.get(playerId);
        if (!player) continue;
        player.score += gain;
      }
      broadcastChat(room, {
        system: true,
        message: `시민 편 종료 보너스 지급: ${finalDay}일차 기준 +${gain}점`,
      });
    }
  }

  clearRoomTimer(room);
  room.game.inProgress = false;
  room.game.phase = "ended";
  room.game.roles = {};
  room.game.mafiaId = null;
  room.game.policeId = null;
  room.game.doctorId = null;
  room.game.jokerMaskRoles = {};
  room.game.mafiaContinue = null;
  room.game.mafiaDecisionVotes = {};
  room.game.lastMafiaSurvivalGainByPlayer = {};
  room.game.assignedMafiaIds = [];
  room.game.skipMafiaSurvivalScoreThisTurn = false;
  room.game.forceMafiaContinueThisTurn = false;
  resetAbilityState(room);
  room.game.votes = {};
  room.game.executionVotes = {};
  room.game.executionCandidateId = null;
  room.game.lastSelfHealDayByPlayer = {};
  room.game.eliminatedIds = {};
  room.game.oneVsOneBonusAwarded = false;
  room.game.moralRouletteTwoMafiaMode = false;
  room.game.moralRouletteForcedSingleMafia = false;
  room.game.preservedMafiaPlayerId = null;
  room.game.preservedMafiaTurns = 0;
  broadcastChat(room, { system: true, message: `게임 종료: ${reason}` });
  if (room.game.mode === MODE_ORIGINAL) {
    broadcastChat(room, {
      system: true,
      message: reason === "시민 승리" ? "[오리지널 마피아] 결과: 시민 승리" : reason === "마피아 승리" ? "[오리지널 마피아] 결과: 마피아 승리" : `[오리지널 마피아] 결과: ${reason}`,
    });
  }
  if (room.game.mode === MODE_MORAL_ROULETTE) {
    const summary = scoreSummaryLines(room, finalRoles);
    if (summary.length > 0) {
      broadcastChat(room, {
        system: true,
        message: `최종 점수\n${summary.join("\n")}`,
      });
    }
  }
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
    broadcastChat(room, { system: true, message: "마피아 검거 성공! 시민 편 전원 +10점" });
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
  if (playerRole(room, player.id) !== "mafia") {
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
  const shouldResetPlayerRecord = room.game.phase === "ended";

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
  if (shouldResetPlayerRecord) {
    player.score = 0;
  }
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
    rulesVersion: RULES_VERSION,
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
      if (player.roomId) {
        const room = getRoom(player.roomId);
        if (room && room.game.inProgress) {
          safeSend(ws, { type: "error", message: "게임 진행 중에는 닉네임을 변경할 수 없습니다." });
          return;
        }
      }
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
          phaseTimer: null,
          phaseEndsAt: null,
          phaseDurationSec: null,
          mode: MODE_MORAL_ROULETTE,
          roleCounts: defaultRoleCounts(MODE_MORAL_ROULETTE),
          scoreSettings: defaultScoreSettings(),
          roles: {},
          mafiaId: null,
          policeId: null,
          doctorId: null,
          jokerMaskRoles: {},
          votes: {},
          executionVotes: {},
          executionCandidateId: null,
          mafiaContinue: null,
          mafiaDecisionVotes: {},
          lastMafiaSurvivalGainByPlayer: {},
          assignedMafiaIds: [],
          skipMafiaSurvivalScoreThisTurn: false,
          forceMafiaContinueThisTurn: false,
          abilityUsed: {},
          pendingKillTargetId: null,
          pendingHealTargetId: null,
          lastSelfHealDayByPlayer: {},
          eliminatedIds: {},
          lastExecutedId: null,
          lastVoteResult: null,
          oneVsOneBonusAwarded: false,
          moralRouletteTwoMafiaMode: false,
          moralRouletteForcedSingleMafia: false,
          preservedMafiaPlayerId: null,
          preservedMafiaTurns: 0,
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
      if (room.players.size >= MAX_ROOM_PLAYERS) {
        safeSend(ws, { type: "error", message: `최대 ${MAX_ROOM_PLAYERS}명까지만 입장할 수 있습니다.` });
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

    if (type === "set_game_mode") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureHost(player, room)) return;
      if (room.game.inProgress) {
        safeSend(ws, { type: "error", message: "게임 진행 중에는 모드를 변경할 수 없습니다." });
        return;
      }

      const mode = String(packet.mode || "").trim().toLowerCase();
      if (mode !== MODE_ORIGINAL && mode !== MODE_MORAL_ROULETTE) {
        safeSend(ws, { type: "error", message: "지원하지 않는 게임 모드입니다." });
        return;
      }

      room.game.mode = mode;
      room.game.roleCounts = defaultRoleCounts(mode);
      room.game.scoreSettings = defaultScoreSettings();
      broadcastRoomUpdate(room);
      broadcastChat(room, {
        system: true,
        message: `게임 모드가 ${mode === MODE_ORIGINAL ? "오리지널 마피아" : "Moral Roulette"}로 변경되었습니다.`,
      });
      return;
    }

    if (type === "set_score_settings") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureHost(player, room)) return;
      if (room.game.inProgress) {
        safeSend(ws, { type: "error", message: "게임 진행 중에는 점수 방식을 변경할 수 없습니다." });
        return;
      }

      room.game.scoreSettings = normalizeScoreSettings(packet.scoreSettings || {});
      broadcastRoomUpdate(room);
      broadcastChat(room, {
        system: true,
        message: `점수 설정 변경: 마피아(조커2+ ${room.game.scoreSettings.mafiaJoker2Plus}, 조커1 ${room.game.scoreSettings.mafiaJoker1}, 조커0 ${room.game.scoreSettings.mafiaJoker0}), 시민 종료배수 x${room.game.scoreSettings.citizenEndMultiplier}`,
      });
      return;
    }

    if (type === "set_role_counts") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureHost(player, room)) return;
      if (room.game.inProgress) {
        safeSend(ws, { type: "error", message: "게임 진행 중에는 직업 수를 변경할 수 없습니다." });
        return;
      }
      if (room.game.mode === MODE_MORAL_ROULETTE) {
        safeSend(ws, { type: "error", message: "Moral Roulette 모드에서는 직업 수가 생존 인원에 따라 자동 배정됩니다." });
        return;
      }

      const counts = normalizeRoleCounts(room.game.mode, packet.roleCounts || {});
      const sum = counts.mafia + counts.doctor + counts.police + counts.joker;
      if (sum > room.players.size) {
        safeSend(ws, { type: "error", message: `직업 수 합계(${sum})가 현재 인원(${room.players.size})보다 많습니다.` });
        return;
      }
      if (sum > MAX_ROOM_PLAYERS) {
        safeSend(ws, { type: "error", message: `직업 수 합계는 최대 ${MAX_ROOM_PLAYERS}명까지 가능합니다.` });
        return;
      }

      room.game.roleCounts = counts;
      broadcastRoomUpdate(room);
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

      const configured = effectiveRoleCounts(room, room.players.size);
      const configuredTotal = configured.mafia + configured.doctor + configured.police + configured.joker;
      if (configuredTotal > room.players.size) {
        safeSend(ws, {
          type: "error",
          message: `직업 수 합계(${configuredTotal})가 현재 인원(${room.players.size})보다 많습니다.`,
        });
        return;
      }
      if (room.game.mode === MODE_ORIGINAL) {
        room.game.roleCounts = configured;
      }

      room.game.inProgress = true;
      room.game.day = 1;
      room.game.phase = "ability";
      room.game.eliminatedIds = {};
      room.game.policeId = null;
      room.game.doctorId = null;
      room.game.jokerMaskRoles = {};
      room.game.lastSelfHealDayByPlayer = {};
      room.game.oneVsOneBonusAwarded = false;
      room.game.mafiaDecisionVotes = {};
      room.game.lastMafiaSurvivalGainByPlayer = {};
      room.game.assignedMafiaIds = [];
      room.game.skipMafiaSurvivalScoreThisTurn = false;
      room.game.forceMafiaContinueThisTurn = false;
      room.game.moralRouletteTwoMafiaMode = room.game.mode === MODE_MORAL_ROULETTE && room.players.size >= 10;
      room.game.moralRouletteForcedSingleMafia = false;
      room.game.preservedMafiaPlayerId = null;
      room.game.preservedMafiaTurns = 0;
      resetAbilityState(room);
      const ok = assignRoles(room);
      if (!ok) {
        finishGame(room, "인원 부족");
        return;
      }
      broadcastChat(room, {
        system: true,
        message: "게임 시작! 1일차 밤 능력 사용 단계입니다. 대상 플레이어를 선택하세요. (30초)",
      });
      setRoomTimer(room, 30, () => {
        startVotingPhase(room);
      });
      broadcastRoomUpdate(room);
      broadcastRoomsList();
      return;
    }

    if (type === "start_voting") {
      safeSend(ws, { type: "error", message: "투표는 자동으로 시작됩니다." });
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

      if (isEliminated(room, player.id)) {
        safeSend(ws, { type: "error", message: "탈락한 플레이어는 투표할 수 없습니다." });
        return;
      }

      const targetId = packet.targetId ? String(packet.targetId) : null;
      if (targetId && !room.players.has(targetId)) {
        safeSend(ws, { type: "error", message: "유효하지 않은 투표 대상입니다." });
        return;
      }
      if (targetId && isEliminated(room, targetId)) {
        safeSend(ws, { type: "error", message: "탈락한 플레이어에게는 투표할 수 없습니다." });
        return;
      }

      room.game.votes[player.id] = targetId;
      const voterName = player.name || player.id;
      broadcastChat(room, {
        system: true,
        centerNotice: true,
        message: `${voterName}님이 투표를 완료했습니다.`,
      });
      sendPrivate(
        player.id,
        targetId
          ? `투표 완료: ${players.get(targetId)?.name || targetId}님에게 투표했습니다.`
          : "투표 완료: 기권 투표를 선택했습니다.",
        room.game.day,
        { danger: true }
      );
      sendPrivateSystemChat(player.id, {
        message: targetId
          ? `투표 완료: ${players.get(targetId)?.name || targetId}님에게 투표했습니다.`
          : "투표 완료: 기권 투표를 선택했습니다.",
        highlightDanger: true,
      });

      const aliveIds = alivePlayerIds(room);
      const votedCount = aliveIds.filter((id) => Object.prototype.hasOwnProperty.call(room.game.votes, id)).length;
      if (votedCount >= aliveIds.length && room.game.phaseEndsAt) {
        const remainMs = room.game.phaseEndsAt - Date.now();
        if (remainMs > 5000) {
          setRoomTimer(room, 5, () => {
            resolveVotingAndAdvance(room);
          });
          broadcastChat(room, {
            system: true,
            message: "전원 투표 완료! 5초 후 결과를 처리합니다.",
          });
        }
      }

      broadcastRoomUpdate(room);
      return;
    }

    if (type === "set_execution_vote") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureInGame(player, room)) return;
      if (room.game.phase !== "execution_vote") {
        safeSend(ws, { type: "error", message: "현재는 처형 찬반 투표 단계가 아닙니다." });
        return;
      }
      if (isEliminated(room, player.id)) {
        safeSend(ws, { type: "error", message: "탈락한 플레이어는 찬반 투표를 할 수 없습니다." });
        return;
      }

      const approve = packet.approve;
      if (typeof approve !== "boolean") {
        safeSend(ws, { type: "error", message: "찬반 투표 값이 올바르지 않습니다." });
        return;
      }

      room.game.executionVotes[player.id] = approve;
      sendPrivate(
        player.id,
        `처형 찬반 투표 완료: ${approve ? "찬성" : "반대"}을 선택했습니다.`,
        room.game.day,
        { danger: true }
      );
      sendPrivateSystemChat(player.id, {
        message: `처형 찬반 투표 완료: ${approve ? "찬성" : "반대"}을 선택했습니다.`,
        highlightDanger: true,
      });

      const aliveIds = alivePlayerIds(room);
      const votedCount = aliveIds.filter((id) => Object.prototype.hasOwnProperty.call(room.game.executionVotes, id)).length;
      if (votedCount >= aliveIds.length && room.game.phaseEndsAt) {
        const remainMs = room.game.phaseEndsAt - Date.now();
        if (remainMs > 5000) {
          setRoomTimer(room, 5, () => {
            resolveExecutionApproval(room);
          });
          broadcastChat(room, {
            system: true,
            message: "처형 찬반 전원 투표 완료! 5초 후 결과를 처리합니다.",
          });
        }
      }

      broadcastRoomUpdate(room);
      return;
    }

    if (type === "close_voting") {
      safeSend(ws, { type: "error", message: "투표 마감은 자동으로 처리됩니다." });
      return;
    }

    if (type === "mafia_continue") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureInGame(player, room)) return;
      if (room.game.phase !== "mafia_decision") {
        safeSend(ws, { type: "error", message: "현재는 마피아 진행 선택 단계가 아닙니다." });
        return;
      }
      if (!ensureMafia(player, room)) return;
      if (room.game.forceMafiaContinueThisTurn) {
        safeSend(ws, { type: "error", message: "이번 턴은 마피아 진행 선택이 자동으로 계속 진행 처리됩니다." });
        return;
      }

      let shouldContinue = null;
      if (typeof packet.continue === "boolean") {
        shouldContinue = packet.continue;
      }
      const decision = String(packet.decision || "").toLowerCase();
      if (decision === "continue") {
        shouldContinue = true;
      } else if (decision === "stop") {
        shouldContinue = false;
      }
      if (typeof shouldContinue !== "boolean") {
        safeSend(ws, { type: "error", message: "진행 선택 값이 올바르지 않습니다." });
        return;
      }

      room.game.mafiaDecisionVotes[player.id] = shouldContinue;
      broadcastChat(room, {
        system: true,
        centerNotice: true,
        message: `${player.name}님이 ${shouldContinue ? "계속 진행" : "스톱"}을 선택했습니다.`,
      });
      sendPrivate(
        player.id,
        `마피아 진행 선택 완료: ${shouldContinue ? "계속 진행" : "스톱"}을 선택했습니다.`,
        room.game.day,
        { danger: true }
      );
      sendPrivateSystemChat(player.id, {
        message: `마피아 진행 선택 완료: ${shouldContinue ? "계속 진행" : "스톱"}을 선택했습니다.`,
        highlightDanger: true,
      });

      const aliveMafia = aliveMafiaIds(room);
      const votedCount = aliveMafia.filter((id) => Object.prototype.hasOwnProperty.call(room.game.mafiaDecisionVotes, id)).length;
      if (votedCount >= aliveMafia.length && aliveMafia.length > 0) {
        resolveMafiaDecisionVotes(room, "마피아 투표 완료! 결과를 처리합니다.");
      } else {
        broadcastRoomUpdate(room);
      }
      return;
    }

    if (type === "use_ability") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room || !ensureInGame(player, room)) return;

      const phase = room.game.phase;
      if (phase !== "ability") {
        safeSend(ws, { type: "error", message: "능력은 밤 능력 단계에서만 사용할 수 있습니다." });
        return;
      }

      if (isEliminated(room, player.id)) {
        safeSend(ws, { type: "error", message: "탈락한 플레이어는 능력을 사용할 수 없습니다." });
        return;
      }

      if (room.game.abilityUsed[player.id]) {
        safeSend(ws, { type: "error", message: "이번 턴에는 이미 능력을 사용했습니다." });
        return;
      }

      const role = playerRole(room, player.id);
      const ability = String(packet.ability || "");

      if (role === "citizen" && ability === "inspect") {
        safeSend(ws, { type: "error", message: "시민은 역할 확인 능력을 사용할 수 없습니다." });
        return;
      }

      if (role === "police" && ability === "inspect") {
        const targetId = String(packet.targetId || "");
        if (!room.players.has(targetId)) {
          safeSend(ws, { type: "error", message: "대상을 찾을 수 없습니다." });
          return;
        }
        if (isEliminated(room, targetId)) {
          safeSend(ws, { type: "error", message: "탈락한 플레이어는 조사할 수 없습니다." });
          return;
        }
        const targetName = players.get(targetId)?.name || targetId;
        const apparentRole = apparentRoleOf(room, targetId);
        const isMafia = apparentRole === "mafia";
        const resultText = isMafia
          ? `${targetName}님의 조사 결과: 마피아입니다.`
          : `${targetName}님의 조사 결과: 마피아가 아닙니다.`;
        sendPrivate(player.id, resultText, room.game.day, { danger: isMafia });
        sendPrivateSystemChat(player.id, {
          message: resultText,
          imageAsset: "police.png",
          highlightDanger: isMafia,
        });
        room.game.abilityUsed[player.id] = true;
        return;
      }

      if (role === "mafia" && ability === "eliminate") {
        const targetId = String(packet.targetId || "");
        if (!room.players.has(targetId)) {
          safeSend(ws, { type: "error", message: "대상을 찾을 수 없습니다." });
          return;
        }
        if (isEliminated(room, targetId)) {
          safeSend(ws, { type: "error", message: "탈락한 플레이어는 대상으로 지정할 수 없습니다." });
          return;
        }
        if (targetId === player.id) {
          safeSend(ws, { type: "error", message: "자기 자신은 탈락 대상으로 지정할 수 없습니다." });
          return;
        }
        const targetName = players.get(targetId)?.name || targetId;
        room.game.pendingKillTargetId = targetId;
        room.game.abilityUsed[player.id] = true;
        sendPrivate(player.id, `${targetName}님을 밤 탈락 대상으로 지정했습니다.`, room.game.day, { danger: true });
        sendPrivateSystemChat(player.id, {
          message: `${targetName}님을 밤 탈락 대상으로 지정했습니다.`,
          highlightDanger: true,
        });
        return;
      }

      if (role === "doctor" && ability === "heal") {
        const targetId = String(packet.targetId || "");
        if (!room.players.has(targetId)) {
          safeSend(ws, { type: "error", message: "대상을 찾을 수 없습니다." });
          return;
        }
        if (isEliminated(room, targetId)) {
          safeSend(ws, { type: "error", message: "탈락한 플레이어는 치료할 수 없습니다." });
          return;
        }
        if (!canUseSelfHeal(room, player.id, targetId)) {
          safeSend(ws, { type: "error", message: "의사는 연속으로 자기 자신을 치료할 수 없습니다." });
          return;
        }
        const targetName = players.get(targetId)?.name || targetId;
        room.game.pendingHealTargetId = targetId;
        room.game.abilityUsed[player.id] = true;
        markSelfHealIfNeeded(room, player.id, targetId);
        sendPrivate(player.id, `${targetName}님을 치료 대상으로 지정했습니다.`, room.game.day, { danger: true });
        sendPrivateSystemChat(player.id, {
          message: `${targetName}님을 치료 대상으로 지정했습니다.`,
          highlightDanger: true,
        });
        return;
      }

      if (role === "joker" && ability === "joker_act") {
        const targetId = String(packet.targetId || "");
        if (!room.players.has(targetId)) {
          safeSend(ws, { type: "error", message: "대상을 찾을 수 없습니다." });
          return;
        }
        if (isEliminated(room, targetId)) {
          safeSend(ws, { type: "error", message: "탈락한 플레이어는 대상으로 지정할 수 없습니다." });
          return;
        }
        const targetName = players.get(targetId)?.name || targetId;
        const fakeRole = room.game.jokerMaskRoles[player.id] || "citizen";
        if (fakeRole === "mafia") {
          room.game.abilityUsed[player.id] = true;
          sendPrivate(player.id, `${targetName}님을 밤 탈락 대상으로 지정했습니다. (조커: 실제 효과 없음)`, room.game.day, { danger: true });
          sendPrivateSystemChat(player.id, {
            message: `${targetName}님을 밤 탈락 대상으로 지정했습니다. (조커: 실제 효과 없음)`,
            imageAsset: "mafia.png",
            highlightDanger: true,
          });
          return;
        }
        if (fakeRole === "doctor") {
          if (!canUseSelfHeal(room, player.id, targetId)) {
            safeSend(ws, { type: "error", message: "조커(의사 위장)는 연속으로 자기 자신을 치료하는 시늉을 할 수 없습니다." });
            return;
          }
          markSelfHealIfNeeded(room, player.id, targetId);
          room.game.abilityUsed[player.id] = true;
          sendPrivate(player.id, `${targetName}님을 치료 대상으로 지정했습니다. (조커: 실제 효과 없음)`, room.game.day, { danger: true });
          sendPrivateSystemChat(player.id, {
            message: `${targetName}님을 치료 대상으로 지정했습니다. (조커: 실제 효과 없음)`,
            imageAsset: "doctor_success.png",
            highlightDanger: true,
          });
          return;
        }
        if (fakeRole === "police") {
          room.game.abilityUsed[player.id] = true;
          sendPrivate(player.id, `${targetName}님을 조사했습니다. (조커: 실제 효과 없음)`, room.game.day, { danger: true });
          sendPrivateSystemChat(player.id, {
            message: `${targetName}님을 조사했습니다. (조커: 실제 효과 없음)`,
            imageAsset: "police.png",
            highlightDanger: true,
          });
          return;
        }
        room.game.abilityUsed[player.id] = true;
        sendPrivate(player.id, `${targetName}님에게 능력을 사용했습니다. (조커: 실제 효과 없음)`, room.game.day, { danger: true });
        sendPrivateSystemChat(player.id, {
          message: `${targetName}님에게 능력을 사용했습니다. (조커: 실제 효과 없음)`,
          highlightDanger: true,
        });
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

      if (room.game.inProgress && room.game.phase === "ability") {
        const senderRole = playerRole(room, player.id);
        if (senderRole === "mafia" && !isEliminated(room, player.id)) {
          const mafiaOnly = aliveMafiaIds(room);
          broadcastChatTo(room, mafiaOnly, {
            fromId: player.id,
            fromName: `${player.name} (마피아)`,
            message: text,
            system: false,
          });
          return;
        }
        safeSend(ws, { type: "error", message: "밤 능력 단계에서는 채팅할 수 없습니다. (마피아 전용 채팅 제외)" });
        return;
      }

      const senderEliminated = isEliminated(room, player.id);
      if (room.game.inProgress && senderEliminated) {
        const spectators = alivePlayerIds(room).length === 0
          ? [...room.players]
          : [...room.players].filter((id) => isEliminated(room, id));

        broadcastChatTo(room, spectators, {
          fromId: player.id,
          fromName: `${player.name} (관전자)`,
          message: text,
          system: false,
        });
        return;
      }

      broadcastChat(room, {
        fromId: player.id,
        fromName: player.name,
        message: text,
        system: false,
      });
      return;
    }

    if (type === "send_emoji") {
      if (!ensureInRoom(player)) return;
      const room = getRoom(player.roomId);
      if (!room) return;
      const emoji = String(packet.emoji || "").trim();
      if (!ALLOWED_EMOJIS.has(emoji)) {
        safeSend(ws, { type: "error", message: "지원하지 않는 이모티콘입니다." });
        return;
      }

      if (room.game.inProgress && room.game.phase === "ability") {
        if (!isEliminated(room, player.id)) {
          broadcastChat(room, {
            fromId: player.id,
            fromName: player.name,
            message: emoji,
            system: false,
            isEmoji: true,
          });
          return;
        }

        safeSend(ws, { type: "error", message: "탈락한 플레이어는 밤 능력 단계에서 이모티콘을 보낼 수 없습니다." });
        return;
      }

      const senderEliminated = isEliminated(room, player.id);
      if (room.game.inProgress && senderEliminated) {
        const spectators = alivePlayerIds(room).length === 0
          ? [...room.players]
          : [...room.players].filter((id) => isEliminated(room, id));

        broadcastChatTo(room, spectators, {
          fromId: player.id,
          fromName: `${player.name} (관전자)`,
          message: emoji,
          system: false,
          isEmoji: true,
        });
        return;
      }

      broadcastChat(room, {
        fromId: player.id,
        fromName: player.name,
        message: emoji,
        system: false,
        isEmoji: true,
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

const discoverySocket = dgram.createSocket("udp4");

discoverySocket.on("error", (error) => {
  console.error("LAN discovery socket error:", error.message);
});

discoverySocket.on("message", (msg, rinfo) => {
  const text = msg.toString().trim();
  if (text !== DISCOVERY_MAGIC) return;

  const response = {
    magic: "GUILNOCENT_SERVER",
    name: "Guilnocent Server",
    wsUrl: `ws://${getLanIpv4() || "127.0.0.1"}:${PORT}`,
    port: PORT,
    rulesVersion: RULES_VERSION,
  };

  discoverySocket.send(
    Buffer.from(JSON.stringify(response)),
    rinfo.port,
    rinfo.address
  );
});

discoverySocket.bind(DISCOVERY_PORT, "0.0.0.0", () => {
  discoverySocket.setBroadcast(true);
  console.log(`LAN discovery UDP listening on 0.0.0.0:${DISCOVERY_PORT}`);
});
