extends PanelContainer
## Allows players to send bugreports and feedback to the dev from inside the game using a discord webhook
class_name BugReporter

## path of the config file that is loaded.
## Will automatically reload
@export var cfg_path := "res://addons/BugReporter/webhook.cfg":
	set(val):
		cfg_path = val
		_reload_cfg()
## If true the Bugreporter will hide after the sending is complete
@export var hide_after_send := true
## If true all input fields will be cleared after sending is complete
@export var clear_after_send := true

var _cfg : ConfigFile


@onready var _http := $HTTPRequest
@onready var _screenshot : TextureRect = find_child("ScreenshotTexture")
@onready var _screenshot_check : Button = find_child("ScreenshotButton")
@onready var _mail_line_edit : LineEdit = find_child("ContactLineEdit")
@onready var _message_text : TextEdit = find_child("MessageText")
@onready var _options : Button = find_child("MessageOptions")
@onready var _analytics_button : Button = find_child("AnalyticsButton")
@onready var _send_button : Button = find_child("SendButton")


func _ready():
	_reload_cfg()

func _reload_cfg():
	_cfg = ConfigFile.new()
	var err := _cfg.load(cfg_path)
	if err != OK:
		push_error("Bugreporter couldn't load config. Reason: %s" % error_string(err))
	if is_instance_valid(_analytics_button):
		_analytics_button.visible = _cfg.get_value("webhook", "send_log", false) or _cfg.get_value("webhook", "send_analytics", false)


func _input(event):
	if event.is_action("screenshot") and event.is_pressed() and !event.is_echo():
		var img := get_viewport().get_texture().get_image()
		var text := ImageTexture.create_from_image(img)
		_screenshot.texture = text
		_screenshot_check.disabled = false


func _on_SendButton_pressed():
	var analytics := false
	if is_instance_valid(_analytics_button): _analytics_button.pressed
	
	send_report(_options.text, 
	_message_text.text, 
	_mail_line_edit.text,
	bool(_cfg.get_value("webhook", "send_log", false)) and analytics,
	bool(_cfg.get_value("webhook", "send_analytics", false)) and analytics
	)


func send_report(message_type: String, message:String, contact_info:String, attach_log_file:=false, attach_analytics_file:=false):
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	
	var player_id := "playerid: %s" % _unique_user_id()
	if _cfg.get_value("webhook", "anonymous_players", false):
		player_id = "anonymous"
	message = message.replace("```", "")
	var request_body := []# 1st place is reserved for json_payload
	
	
	var json_payload := {
		"username" : "%s:" % _get_game_name(),
		"tts" : _cfg.get_value("webhook", "tts", false),
		"attachments": []
	}
	
	if attach_log_file:
		request_body.push_back("user://logs/godot.log")
		json_payload["attachments"].push_back({"id":0})
	if attach_analytics_file:
		var report := AnalyticsReport.new(get_tree())
		json_payload["attachments"].push_back({"id":int(request_body.size()), "filename":"%s.txt" % report.get_name()})
		request_body.push_back(report)
	
	var embed = {
			"title": "%s by %s" % [message_type, player_id],
			"color": _cfg.get_value("webhook", "color", 15258703),
		}
	var fields := []
	
	if !contact_info.is_empty():
		fields.push_back({
				"name" : "Contact Info:",
				"value" : contact_info
		})
	
	if !message.is_empty():
		fields.push_back({
				"name" : "Message:",
				"value" : "```\n%s\n```" % message,
			}
	)
	
	if _screenshot_check.button_pressed:
		embed["image"] = {
					"url" : "attachment://screenshot%s.png" % request_body.size(),
				}
		
		var id := int(request_body.size())
		json_payload["attachments"].push_back({"id": id, "filename": "screenshot%s.png" % id})
		request_body.push_back(_screenshot.texture)
	
	embed["fields"] = fields
	json_payload["embeds"] = [embed]
	
	request_body.push_front(json_payload)
	var boundary := "b%s" % hash(str(Time.get_unix_time_from_system(), message))
	var payload := _array_to_form_data(request_body, boundary)
	
	if fields.is_empty():
		return
	
	_http.request(_cfg.get_value("webhook", "url", ""), 
			PackedStringArray(["connection: keep-alive", "Content-type: multipart/form-data; boundary=%s" % boundary]), 
			HTTPClient.METHOD_POST,
			payload
	)
	
	_send_button.disabled = true
	print("BugReporter message send")

func clear():
	_message_text.clear()
	


func _on_HTTPRequest_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
	_send_button.disabled = false
	if hide_after_send:
		hide()
	if clear_after_send:
		clear()
		$VBox/Message.text = ""
	if ![200, 204].has(response_code):
		printerr("BugReporter Error sending Report. Result: %s Responsecode: %s Body: %s" % [result, response_code, body.get_string_from_ascii()])


func _unique_user_id() -> String:
	if OS.get_name() == "Web":
		return "Webuser"
	return str(hash(str(OS.get_unique_id(), "|", _get_game_name())))

func _get_game_name():
	return _cfg.get_value("webhook", "game_name", "unnamed_game")


## Converts a texture into the corresponding bytes but limited to a max size
func _texture_to_png_bytes(texture : Texture2D, max_size:=8000)->PackedByteArray:
	var img := texture.get_image()
	var bytes : PackedByteArray = img.save_png_to_buffer()
	
	while bytes.size() > max_size:
		img.resize(img.get_width()/2, img.get_height()/2)
		bytes = img.save_png_to_buffer()
	
	return bytes


## converts an array of [Variant] into the closest multipart form data equivalent. 
func _array_to_form_data(array:Array, boundary:="boundary")->String:
	# Discord example request
#	-boundary
#	Content-Disposition: form-data; name="content"
#
#	Hello, World!
#	--boundary
#	Content-Disposition: form-data; name="tts"
#
#	true
#	--boundary--
#	
	var file_counter := 0
	var output = ""
	
	for element in array:
		output += "--%s\n" % boundary
		
		if element is Dictionary:
			output += 'Content-Disposition: form-data; name="payload_json"\nContent-Type: application/json\n\n'
			output += JSON.new().stringify(element, "	") + "\n"
			
		elif element is Texture2D:
			output += 'Content-Type: image/png\n'
			output += 'Content-Disposition: attachment; filename="screenshot%s.png"; name="files[%s]";\n' % [file_counter, file_counter]
			output += 'Content-Transfer-Encoding: base64\nX-Attachment-Id: f_ljiz6nfz0\nContent-ID: <f_ljiz6nfz0>'
			output += "\n\n"
			output += Marshalls.raw_to_base64(_texture_to_png_bytes(element)) + "\n"
			file_counter += 1
		elif element is String:
			if element.is_absolute_path():
				var f := FileAccess.open(element, FileAccess.READ)
				if FileAccess.get_open_error() == OK:
					var file := f.get_as_text()
					f.close()
					if !file.is_empty():
						output += 'Content-Type: plain/text"\n'
						output += 'Content-Disposition: attachment; filename="%s"; name="files[%s]";\n' % [element.get_file(), file_counter]
						output += "\n"
						output += file
				else:
					printerr("BugReporter could not attach File %s to Message, Reason: %s" % [element, error_string(FileAccess.get_open_error())])
				file_counter+=1
		elif element is AnalyticsReport:
			output += 'Content-Type: plain/text\n'
			output += 'Content-Disposition: attachment; filename="%s.txt"; name="files[%s]"\n' % [element.get_name(), file_counter]
			output += "\n"
			output += str(element)
			file_counter+=1
	
	output += "--%s--" % boundary
	return output


class AnalyticsReport:
	var timestamp:int
	var os_name:String
	var nodes := {}
	
	func _init(tree:SceneTree):
		timestamp = Time.get_unix_time_from_system()
		os_name = "%s-%s" % [OS.get_name(), OS.get_version()]
		for node in tree.get_nodes_in_group("analize"):
			var val := ""
			if node.has_method("analize"):
				val = str(node.analize())
			else:
				val = str(node)
			nodes[node.get_path().get_concatenated_names()] = val
		nodes.make_read_only()
	
	func get_name()->String:
		return ("Report-%s-%s" % [timestamp, os_name]).replace(".", "-")
	
	
	func _to_string():
		var out := get_name()+ "\n"
		for key in nodes.keys():
			out+= "\n%s\n%s\n" % [key, nodes[key]]
		return out

