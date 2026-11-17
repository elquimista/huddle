#!/usr/bin/env python3
"""Fills the local Synapse with rooms and messages for testing Huddle Dev.

Run after setup.sh. Does nothing if alice already has rooms.

  seed.py                                   rooms, history, images, a DM, an encrypted room, an invite
  seed.py threads                           three threads in General, one long
  seed.py audio                             voice messages and audio files in General
  seed.py say <user> <room> <text>          one live message
  seed.py read <user> <room> [fragment]     send a read receipt, for the newest message or a named one
  seed.py reply <user> <room> <fragment> <text>   one reply in the thread whose text contains <fragment>
  seed.py respond <user> <room> <fragment> <text> an inline reply to the message containing <fragment>
"""
import json, os, struct, sys, urllib.error, urllib.parse, urllib.request, uuid, zlib

def load_env():
    env = {}
    for line in open(os.path.join(os.path.dirname(__file__), "dev.env")):
        if "=" in line and not line.startswith("#"):
            key, value = line.strip().split("=", 1)
            env[key] = value.strip('"')
    return env

ENV = load_env()
BASE = ENV["HUDDLE_DEV_SERVER"]

def call(method, path, token=None, body=None, raw=None, content_type="application/json"):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(BASE + path, data=data, method=method)
    request.add_header("Content-Type", content_type)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.load(response)

def login(user):
    return call("POST", "/_matrix/client/v3/login", body={
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": user},
        "password": ENV["HUDDLE_DEV_PASSWORD"],
        "initial_device_display_name": "seed script",
    })["access_token"]

def send(token, room, body, msgtype="m.text", **extra):
    content = {"msgtype": msgtype, "body": body, **extra}
    path = f"/_matrix/client/v3/rooms/{room}/send/m.room.message/{uuid.uuid4().hex}"
    return call("PUT", path, token, content)["event_id"]

def create(token, name, invite=(), **extra):
    body = {"preset": "private_chat", "invite": [f"@{u}:localhost" for u in invite], **extra}
    if name:
        body["name"] = name
    return call("POST", "/_matrix/client/v3/createRoom", token, body)["room_id"]

def join(token, room):
    call("POST", f"/_matrix/client/v3/join/{room}", token, {})

def png(width, height, rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))

def find_room(token, room_name):
    for room in call("GET", "/_matrix/client/v3/joined_rooms", token)["joined_rooms"]:
        try:
            state = call("GET", f"/_matrix/client/v3/rooms/{room}/state/m.room.name", token)
        except urllib.error.HTTPError:
            continue  # unnamed room, such as a direct chat
        if state.get("name") == room_name:
            return room
    sys.exit(f"That user is not in a room named {room_name}")

def reply_in_thread(token, room, root, text):
    return send(token, room, text, **{"m.relates_to": {
        "rel_type": "m.thread", "event_id": root,
        "is_falling_back": True, "m.in_reply_to": {"event_id": root}}})

def find_message(token, room, fragment):
    """Event ID of the newest message in the room whose text contains `fragment`."""
    chunk = call("GET", f"/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=100", token)["chunk"]
    for event in chunk:
        if event["type"] == "m.room.message" and fragment in event["content"].get("body", ""):
            relation = event["content"].get("m.relates_to", {})
            return relation["event_id"] if relation.get("rel_type") == "m.thread" else event["event_id"]
    sys.exit(f"No recent message containing {fragment!r}")

def find_plain_message(token, room, fragment):
    """Event ID of the newest message whose text contains `fragment`, thread reply or not."""
    chunk = call("GET", f"/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=100", token)["chunk"]
    for event in chunk:
        if event["type"] == "m.room.message" and fragment in event["content"].get("body", ""):
            return event["event_id"]
    sys.exit(f"No recent message containing {fragment!r}")

def seed_threads():
    alice, bob, carol = login("alice"), login("bob"), login("carol")
    general = find_room(alice, "General")
    root = send(carol, general, "Where should we go for the team lunch on Thursday?")
    for token, text in ((bob, "The ramen place on 5th is great"), (alice, "Ramen works for me"),
                        (carol, "Booking a table for 12:30 then"), (bob, "Can we make it 12:45? I have a call"),
                        (carol, "Sure, 12:45 it is")):
        reply_in_thread(token, general, root, text)
    root = send(bob, general, "Release checklist for 0.2 is in the wiki")
    reply_in_thread(alice, general, root, "Thanks, reviewing it now")
    send(carol, general, "Back to normal chat after the threads")
    root = send(alice, general, "Long thread: count to forty")
    speakers = (bob, carol, alice)
    for i in range(1, 41):
        reply_in_thread(speakers[i % 3], general, root, f"Thread reply {i}")
    print("Seeded three threads in General.")

def upload(token, name, data, content_type):
    request = urllib.request.Request(f"{BASE}/_matrix/media/v3/upload?filename={urllib.parse.quote(name)}",
                                     data=data, method="POST")
    request.add_header("Content-Type", content_type)
    request.add_header("Authorization", "Bearer " + token)
    return json.load(urllib.request.urlopen(request))["content_uri"]

def seed_audio():
    """Audio in General: voice messages with and without a waveform, files that play natively,
    one that needs the system's Ogg reader, and one that can't be played at all."""
    fixtures = os.path.join(os.path.dirname(__file__), "fixtures")
    meta = json.load(open(os.path.join(fixtures, "audio.json")))
    read = lambda name: open(os.path.join(fixtures, name), "rb").read()
    bob, carol = login("bob"), login("carol")
    general = find_room(bob, "General")

    def audio(token, body, data, mimetype, duration_ms, **extra):
        uri = upload(token, extra.get("filename", body), data, mimetype)
        info = {"mimetype": mimetype, "size": len(data), "duration": duration_ms}
        return send(token, general, body, "m.audio", url=uri, info=info, **extra)

    voice, song, chime = read("voice.ogg"), read("song.mp3"), read("chime.ogg")
    length = meta["voice"]["duration_ms"]
    send(bob, general, "Sending a couple of voice notes about the release")
    audio(bob, "Voice message.ogg", voice, "audio/ogg", length, **{
        "org.matrix.msc3245.voice": {},
        "org.matrix.msc1767.audio": {"duration": length, "waveform": meta["voice"]["waveform"]}})
    audio(carol, "Voice message.ogg", voice, "audio/ogg", length, **{"org.matrix.msc3245.voice": {}})
    audio(bob, "late-night-arpeggio.mp3", song, "audio/mpeg", meta["song"]["duration_ms"])
    audio(carol, "Here's the standup recording, the bit about the launch is near the end", song, "audio/mpeg",
          meta["song"]["duration_ms"], filename="2026-11-17 Standup recording with the whole platform team (final cut).mp3")
    audio(carol, "notification-chime.ogg", chime, "audio/ogg", meta["chime"]["duration_ms"])
    audio(bob, "field-recording.xyz", b"not really audio " * 400, "application/octet-stream", 5000)
    print("Seeded audio in General.")

def main():
    command = sys.argv[1] if len(sys.argv) > 1 else None
    if command == "respond":  # seed.py respond <user> <room> <fragment> <text>: an inline reply
        _, _, user, room_name, fragment, text = sys.argv
        token = login(user)
        room = find_room(token, room_name)
        target = find_plain_message(token, room, fragment)
        print(send(token, room, text, **{"m.relates_to": {"m.in_reply_to": {"event_id": target}}}))
        return
    if command == "audio":    # seed.py audio: voice messages and audio files in General
        seed_audio()
        return
    if command == "say":      # seed.py say <user> <room> <text>: one live message
        _, _, user, room_name, text = sys.argv
        token = login(user)
        print(send(token, find_room(token, room_name), text))
        return
    if command == "reply":    # seed.py reply <user> <room> <text in the thread> <reply>: one thread reply
        _, _, user, room_name, fragment, text = sys.argv
        token = login(user)
        room = find_room(token, room_name)
        print(reply_in_thread(token, room, find_message(token, room, fragment), text))
        return
    if command == "read":     # seed.py read <user> <room> [fragment]: read up to the newest message,
        user, room_name = sys.argv[2], sys.argv[3]  # or up to the one containing <fragment>
        token = login(user)
        room = find_room(token, room_name)
        if len(sys.argv) > 4:
            event = find_plain_message(token, room, sys.argv[4])
        else:
            event = call("GET", f"/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=1", token)["chunk"][0]["event_id"]
        call("POST", f"/_matrix/client/v3/rooms/{room}/receipt/m.read/{event}", token, {})
        print(event)
        return
    if command == "threads":  # seed.py threads: three threads in General
        seed_threads()
        return

    alice, bob, carol = login("alice"), login("bob"), login("carol")
    if call("GET", "/_matrix/client/v3/joined_rooms", alice)["joined_rooms"]:
        print("Already seeded.")
        return

    call("PUT", "/_matrix/client/v3/profile/@alice:localhost/displayname", alice, {"displayname": "Alice"})
    call("PUT", "/_matrix/client/v3/profile/@bob:localhost/displayname", bob, {"displayname": "Bob"})
    call("PUT", "/_matrix/client/v3/profile/@carol:localhost/displayname", carol, {"displayname": "Carol"})

    # A long room, for scrolling back through history.
    general = create(alice, "General", invite=["bob", "carol"], topic="Everything and nothing")
    join(bob, general); join(carol, general)
    speakers = [("alice", alice), ("bob", bob), ("carol", carol)]
    for i in range(1, 181):
        _, token = speakers[(i // 3) % 3]
        send(token, general, f"History message {i}")
    send(bob, general, "Docs are at https://matrix.org/docs/ if anyone needs them")
    target = send(carol, general, "Shipping the new build on Friday")
    for token in (alice, bob):
        call("PUT", f"/_matrix/client/v3/rooms/{general}/send/m.reaction/{uuid.uuid4().hex}", token,
             {"m.relates_to": {"rel_type": "m.annotation", "event_id": target, "key": "🎉"}})

    # Images, an emote and a file.
    design = create(bob, "Design", invite=["alice"])
    join(alice, design)
    send(bob, design, "Two options for the accent colour:")
    for name, rgb, size in (("teal.png", (20, 150, 140), (640, 360)), ("coral.png", (240, 110, 90), (300, 500))):
        request = urllib.request.Request(f"{BASE}/_matrix/media/v3/upload?filename={name}",
                                         data=png(*size, rgb), method="POST")
        request.add_header("Content-Type", "image/png")
        request.add_header("Authorization", "Bearer " + bob)
        uri = json.load(urllib.request.urlopen(request))["content_uri"]
        send(bob, design, name, "m.image", url=uri, info={"w": size[0], "h": size[1], "mimetype": "image/png"})
    send(alice, design, "prefers the teal one", "m.emote")
    send(bob, design, "brand-guide.pdf", "m.file", url="mxc://localhost/missing", info={"mimetype": "application/pdf"})
    send(bob, design, "Multi-line message:\nline two\nline three")

    # A direct chat.
    dm = create(bob, None, invite=["alice"], is_direct=True)
    join(alice, dm)
    call("PUT", f"/_matrix/client/v3/user/@alice:localhost/account_data/m.direct", alice, {"@bob:localhost": [dm]})
    send(bob, dm, "Hey Alice, got a minute?")

    # An encrypted room: only real clients can talk here.
    create(alice, "Encrypted", invite=["bob"],
           initial_state=[{"type": "m.room.encryption", "state_key": "",
                           "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])
    # Bob joins from the app, so his device is there to receive keys.

    # A pending invitation.
    create(carol, "Secret Project", invite=["alice"])
    print("Seeded: General, Design, a DM with Bob, Encrypted, and an invite to Secret Project.")

if __name__ == "__main__":
    main()
