extends Node

var tcp_server = TCPServer.new()
var peers = {}

var players = {}
var player_inputs = {}
var player_rotations = {}
var uid_to_id = {}
var next_id = 1

const GRAVITY = -9.8
const MOVE_SPEED = 100.0
const FRICTION = 0.92
const MAX_SPEED = 10000.0

func _ready():
	var err = tcp_server.listen(8000)
	if err == OK:
		print("🟢 Сервер запущен на порту 8000")
	else:
		print("❌ Ошибка: ", err)

func _process(delta):
	while tcp_server.is_connection_available():
		var peer = tcp_server.take_connection()
		if peer == null:
			continue
		var id = randi()
		peers[id] = {
			"tcp": peer,
			"buffer": PackedByteArray(),
			"handshake_done": false,
			"player_id": -1,
			"uid": ""
		}
		print("🟢 Клиент подключился: ", id)
	
	var to_remove = []
	for id in peers.keys():
		var p = peers[id]
		p["tcp"].poll()
		
		if p["tcp"].get_status() != StreamPeerTCP.STATUS_CONNECTED:
			to_remove.append(id)
			continue
		
		if p["tcp"].get_available_bytes() > 0:
			var size = p["tcp"].get_available_bytes()
			var chunk = p["tcp"].get_data(size)[1]
			p["buffer"].append_array(chunk)
			
			if not p["handshake_done"]:
				var data = p["buffer"].get_string_from_utf8()
				if data.contains("\r\n\r\n"):
					var key = ""
					for line in data.split("\r\n"):
						if line.begins_with("Sec-WebSocket-Key:"):
							key = line.split(":")[1].strip_edges()
							break
					if key != "":
						var accept = _generate_accept_key(key)
						var response = "HTTP/1.1 101 Switching Protocols\r\n"
						response += "Upgrade: websocket\r\n"
						response += "Connection: Upgrade\r\n"
						response += "Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
						p["tcp"].put_data(response.to_utf8_buffer())
						p["handshake_done"] = true
						var http_end = data.find("\r\n\r\n") + 4
						if http_end < p["buffer"].size():
							p["buffer"] = p["buffer"].slice(http_end)
						else:
							p["buffer"] = PackedByteArray()
						print("🤝 Handshake done: ", id)
			
			if p["handshake_done"]:
				while p["buffer"].size() > 0:
					var frame = _parse_frame(p["buffer"])
					if frame == null:
						break
					p["buffer"] = p["buffer"].slice(frame["total_len"])
					
					match frame["opcode"]:
						0x01:
							var msg_data = frame["payload"].get_string_from_utf8()
							var msg = JSON.parse_string(msg_data)
							if msg != null:
								_handle_message(id, msg)
						0x08:
							to_remove.append(id)
						0x09:
							_send_raw(id, 0x8A, frame["payload"])
	
	for id in to_remove:
		_disconnect(id)
	
	_game_loop(delta)

func _parse_frame(buffer):
	if buffer.size() < 2:
		return null
	
	var opcode = buffer[0] & 0x0F
	var masked = (buffer[1] & 0x80) != 0
	var length = buffer[1] & 0x7F
	var pos = 2
	
	if length == 126:
		if buffer.size() < 4:
			return null
		length = (buffer[2] << 8) | buffer[3]
		pos = 4
	elif length == 127:
		if buffer.size() < 10:
			return null
		length = 0
		for i in range(8):
			length = (length << 8) | buffer[2 + i]
		pos = 10
	
	var mask_key = PackedByteArray()
	if masked:
		if buffer.size() < pos + 4:
			return null
		mask_key = buffer.slice(pos, pos + 4)
		pos += 4
	
	if buffer.size() < pos + length:
		return null
	
	var payload = buffer.slice(pos, pos + length)
	if masked:
		for i in range(payload.size()):
			payload[i] ^= mask_key[i % 4]
	
	return {
		"opcode": opcode,
		"payload": payload,
		"total_len": pos + length
	}

func _generate_accept_key(key):
	var combined = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	var hash = combined.sha1_buffer()
	return Marshalls.raw_to_base64(hash)

func _disconnect(id):
	if not peers.has(id):
		return
	print("🔴 Клиент отключился: ", id)
	if peers[id]["player_id"] != -1:
		var player_id = peers[id]["player_id"]
		players[player_id]["online"] = false
	peers.erase(id)

func _handle_message(id, msg):
	match msg["type"]:
		"restore":
			_handle_restore(id, msg)
		"new":
			_create_new_player(id)
		"move":
			var player_id = peers[id]["player_id"]
			if player_id != -1:
				player_inputs[player_id] = {
					"move_x": msg.get("x", 0.0),
					"move_z": msg.get("z", 0.0)
				}
		"rotate":
			var player_id = peers[id]["player_id"]
			if player_id != -1:
				player_rotations[player_id] = msg.get("yaw", 0.0)
		"request_state":
			_send_state(id)

func _handle_restore(id, msg):
	var uid = msg.get("uid", "")
	if uid != "" and uid_to_id.has(uid):
		var player_id = uid_to_id[uid]
		peers[id]["player_id"] = player_id
		peers[id]["uid"] = uid
		players[player_id]["online"] = true
		print("🔄 Игрок восстановлен: ID=", player_id)
		_send_assign_id(id, player_id, uid)
	else:
		_create_new_player(id)

func _create_new_player(id):
	var player_id = next_id
	next_id += 1
	var uid = str(randi()).substr(0, 8)
	peers[id]["player_id"] = player_id
	peers[id]["uid"] = uid
	players[player_id] = {
		"pos": Vector3.ZERO,
		"vel": Vector3.ZERO,
		"online": true,
		"uid": uid
	}
	players[player_id]["pos"].y = 1.0
	uid_to_id[uid] = player_id
	print("🟢 Новый игрок: ID=", player_id)
	_send_assign_id(id, player_id, uid)

func _send_assign_id(id, player_id, uid):
	var msg = {"type": "assign_id", "id": player_id, "uid": uid}
	_send_raw(id, 0x81, JSON.stringify(msg).to_utf8_buffer())
	print("📤 assign_id → ID=", player_id)

func _send_state(id):
	var state = {"type": "state", "players": {}}
	for pid in players:
		if players[pid]["online"]:
			state["players"][str(pid)] = {
				"pos": [players[pid]["pos"].x, players[pid]["pos"].y, players[pid]["pos"].z],
				"rot": player_rotations.get(pid, 0.0)
			}
	var data = JSON.stringify(state).to_utf8_buffer()
	if id == -1:
		for pid in peers:
			_send_raw(pid, 0x81, data)
	else:
		_send_raw(id, 0x81, data)

func _send_raw(id, opcode, payload):
	var frame = PackedByteArray()
	frame.append(0x80 | opcode)
	var length = payload.size()
	if length < 126:
		frame.append(length)
	elif length < 65536:
		frame.append(126)
		frame.append((length >> 8) & 0xFF)
		frame.append(length & 0xFF)
	else:
		frame.append(127)
		for i in range(7, -1, -1):
			frame.append((length >> (i * 8)) & 0xFF)
	frame.append_array(payload)
	peers[id]["tcp"].put_data(frame)

func _game_loop(delta):
	for pid in players:
		if not players[pid]["online"]:
			continue
		var move_x = player_inputs.get(pid, {}).get("move_x", 0.0)
		var move_z = player_inputs.get(pid, {}).get("move_z", 0.0)
		players[pid]["vel"].x += move_x * MOVE_SPEED * delta
		players[pid]["vel"].z += move_z * MOVE_SPEED * delta
		players[pid]["vel"].x *= FRICTION
		players[pid]["vel"].z *= FRICTION
		var speed = sqrt(players[pid]["vel"].x**2 + players[pid]["vel"].z**2)
		if speed > MAX_SPEED:
			players[pid]["vel"].x = (players[pid]["vel"].x / speed) * MAX_SPEED
			players[pid]["vel"].z = (players[pid]["vel"].z / speed) * MAX_SPEED
		players[pid]["pos"].x += players[pid]["vel"].x * delta
		players[pid]["pos"].z += players[pid]["vel"].z * delta
		players[pid]["vel"].y += GRAVITY * delta
		players[pid]["pos"].y += players[pid]["vel"].y * delta
		if players[pid]["pos"].y < 0:
			players[pid]["pos"].y = 0
			players[pid]["vel"].y = 0
	_send_state(-1)
