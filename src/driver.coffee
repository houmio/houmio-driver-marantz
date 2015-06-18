request = require('request')
qs = require('querystring')
Bacon = require('baconjs')
net = require('net')
async = require('async')
carrier = require('carrier')
parseString = require('xml2js').parseString



bridgeAVModeSocket = new net.Socket()
bridgeAVSourceSocket = new net.Socket()
bridgeGeneralSocket = new net.Socket()

RECEIVER_IP = "192.168.0.13"
STATUS_URL = "http://#{RECEIVER_IP}/goform/formMainZone_MainZoneXml.xml"
POST_URL = "http://#{RECEIVER_IP}/MainZone/index.put.asp"

houmioBridge = process.env.HOUMIO_BRIDGE || "localhost:3001"


exit = (msg) ->
  console.log msg
  process.exit 1

readDeviceStatus = ->
  request STATUS_URL, (error, response, body) ->
  	if (!error && response.statusCode == 200) then return body else return null

parseDeviceStateFromMessage = (state) ->
  getValue = (val) -> state.item[val][0].value[0]
  {
    power: getValue('Power'),
    input: getValue('InputFuncSelect'),
    volumeLevel: getValue('MasterVolume'),
    mute: getValue('Mute'),
    surroundMode: getValue('selectSurround')
  }

getDeviceState = (writeMessage, callback) ->
  console.log "TAAALLLAAA"
  request STATUS_URL, (error, response, body) ->
    if (!error && response.statusCode == 200)
      parseString body, (err, result) ->
        writeMessage.deviceState = parseDeviceStateFromMessage result
        console.log writeMessage
        callback writeMessage
    else
      console.log "ERRREERROOOR"
      callback writeMessage


sendAVCommand = (cmd) ->
	body = qs.stringify { cmd0: cmd }
	console.log body
	request.post {
		url: POST_URL,
		body: body
	}, (err,httpResponse,body) ->
		console.log "Written to AVR:", body

writeMessageToAVModeMessage = (writeMessage) ->
  if writeMessage.deviceState.power != 'ON'
    return ["PutZone_OnOff/ON", "PutSurroundMode/#{writeMessage.data.protocolAddress}"]
  else
    return ["PutSurroundMode/#{writeMessage.data.protocolAddress}"]

writeMessageToAVSourceMessage = (writeMessage) ->
  if writeMessage.deviceState.power != 'ON'
    return ["PutZone_OnOff/ON", "PutZone_InputFunction/#{writeMessage.data.protocolAddress}"]
  else
    return ["PutZone_InputFunction/#{writeMessage.data.protocolAddress}"]

writeMessageToGeneralMessage = (writeMessage) ->
  console.log writeMessage
  if writeMessage.data.protocolAddress is 'onoff'
    if writeMessage.data.on then return "PutZone_OnOff/ON" else return "PutZone_OnOff/OFF"
  if writeMessage.data.protocolAddress is 'volume'
    return null
  if writeMessage.data.protocolAddress is 'mute'
    return null
  else
    return null

doWriteToMarantzDevice = (handle) ->
	console.log handle

isWriteMessage = (message) -> message.command is "write"

toLines = (socket) ->
  Bacon.fromBinder (sink) ->
    carrier.carry socket, sink
    socket.on "close", -> sink new Bacon.End()
    socket.on "error", (err) -> sink new Bacon.Error(err)
    ( -> )

openBridgeWriteMessageStream = (socket, protocolName) -> (cb) ->
  socket.connect houmioBridge.split(":")[1], houmioBridge.split(":")[0], ->
    lineStream = toLines socket
    messageStream = lineStream.map JSON.parse
    messageStream.onEnd -> exit "Bridge stream ended, protocol: #{protocolName}"
    messageStream.onError (err) -> exit "Error from bridge stream, protocol: #{protocolName}, error: #{err}"
    writeMessageStream = messageStream.filter isWriteMessage
    cb null, writeMessageStream

openStreams = [openBridgeWriteMessageStream(bridgeAVSourceSocket, "AVSOURCE")
              , openBridgeWriteMessageStream(bridgeAVModeSocket, "AVMODE")
              , openBridgeWriteMessageStream(bridgeGeneralSocket, "GENERAL")]

async.series openStreams, (err, [avsourceWriteMessages, avmodeWriteMessages, generalWriteMessages]) ->
  if err then exit err
  avmodeWriteMessages
    .flatMap (m) -> Bacon.fromCallback (cb) -> getDeviceState m, cb
    .flatMap (m) -> Bacon.fromArray writeMessageToAVModeMessage m
    .bufferingThrottle 50
    .onValue sendAVCommand
  avsourceWriteMessages
    .flatMap (m) -> Bacon.fromCallback (cb) -> getDeviceState m, cb
    .flatMap (m) -> Bacon.fromArray writeMessageToAVSourceMessage m
    .bufferingThrottle 50
    .onValue sendAVCommand
  generalWriteMessages
    .map writeMessageToGeneralMessage
    .onValue sendAVCommand

  bridgeAVSourceSocket.write (JSON.stringify { command: "driverReady", protocol: "marantz/avsource"}) + "\n"
  bridgeAVModeSocket.write (JSON.stringify { command: "driverReady", protocol: "marantz/avmode"}) + "\n"
  bridgeGeneralSocket.write (JSON.stringify { command: "driverReady", protocol: "marantz/general"}) + "\n"


