class_name AuthStore
extends RefCounted

## Local accounts: username, password, role. Backed by a `ConfigFile` at
## `user://accounts.cfg`. Phase 4 moves the store to the host; this surface stays.
##
## The password is never written down -- only a per-account random salt and
## SHA-256(salt + password). A stolen save file yields no passwords, and two
## people who picked the same one do not get the same hash.

const PATH := "user://accounts.cfg"
const MIN_PASSWORD := 8
const ROLES := ["player", "admin"]
## 3-20 of letters, digits, underscore, hyphen. Also keeps `#`, `=` and `[`
## out of a ConfigFile section name, which Godot's parser is known to mangle.
const NAME_PATTERN := "^[A-Za-z0-9_-]{3,20}$"

var _path: String
var _cfg := ConfigFile.new()


func _init(path := PATH) -> void:
	_path = path
	_cfg.load(_path)  # absent file just means nobody has registered yet


## "" on success, else the message to show under the form.
func register(username: String, password: String, role: String) -> String:
	var name := username.strip_edges()
	var re := RegEx.create_from_string(NAME_PATTERN)
	if re.search(name) == null:
		return "Username: 3-20 letters, digits, _ or - only."
	if _cfg.has_section(name.to_lower()):
		return "That username is taken."
	if password.length() < MIN_PASSWORD:
		return "Password must be at least %d characters." % MIN_PASSWORD
	if not ROLES.has(role):
		return "Select a role."
	var salt := Crypto.new().generate_random_bytes(16).hex_encode()
	var key := name.to_lower()
	_cfg.set_value(key, "name", name)
	_cfg.set_value(key, "role", role)
	_cfg.set_value(key, "salt", salt)
	_cfg.set_value(key, "hash", (salt + password).sha256_text())
	_cfg.save(_path)
	return ""


## The account on success, `{}` on failure -- a wrong username and a wrong
## password fail the same way, so the login form cannot enumerate accounts.
func login(username: String, password: String) -> Dictionary:
	var key := username.strip_edges().to_lower()
	if not _cfg.has_section(key):
		return {}
	var salt: String = _cfg.get_value(key, "salt", "")
	if (salt + password).sha256_text() != _cfg.get_value(key, "hash", ""):
		return {}
	return {"name": _cfg.get_value(key, "name"), "role": _cfg.get_value(key, "role")}
