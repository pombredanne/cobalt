#!/usr/bin/env coffee

# serv.ps
# http server for cobalt.

fs      = require 'fs'
child_process = require 'child_process'
os      = require 'os'

express = require 'express'
request = require 'request'
exec    = require('child_process').exec
mongoose = require 'mongoose'

User = require 'models/user'
Box = require 'models/box'
SSHKey = require 'models/ssh_key'

app = express.createServer()

app.use express.bodyParser()

app.configure 'staging', ->
  app.use express.logger()
  app.use express.errorHandler { dumpExceptions: true, showStack: true}

app.configure 'production', ->
  app.use express.logger()
  app.use express.errorHandler()

mongoose.connect process.env['COBALT_DB']

server_ip = '127.0.0.1'
interfaces = os.networkInterfaces()
server_ip = interfaces.eth0[0].address if interfaces.eth0?
root_url = "http://#{server_ip}"
root_url = root_url + ":#{process.env.COBALT_PORT}" unless process.env.COBALT_PORT == '8000'

# Templating language
app.set('view engine', 'ejs')

app.get "/", (req, res) ->
  res.header('Content-Type', 'application/json')
  res.render('index', {rooturl: root_url})

# TODO: should this be middleware?
check_api_key = (req, res, next) ->
  res.header('Content-Type', 'application/json')
  if req.body.apikey?
    url = "https://scraperwiki.com/froth/check_key/#{req.body.apikey}"
    request.get url, (err, resp, body) ->
      if resp.statusCode is 200
        next()
      else
        res.send {error: "Unauthorised"}, 403
  else
    res.send {error: "No API key supplied"}, 403

# Check API key for all POSTs 
app.post /.*/, check_api_key
app.delete /.*/, check_api_key

# Documentation for SSHing to a box.
app.get "/:box_name/?", (req, res) ->
  res.header('Content-Type', 'application/json')
  Box.findOne {name: req.params.box_name}, (err, box) ->
    return res.send { error: "Box not found" }, 404 unless box?
    res.render 'box',
      box_name: req.params.box_name
      rooturl: root_url
      server_ip: server_ip


# Create a box
app.post "/:box_name/?", (req, res) ->
  res.header('Content-Type', 'application/json')
  re = /^[a-zA-Z0-9_+-]+$/
  if not re.test req.params.box_name
     return res.send {error:
       "Box name should match the regular expression #{String(re)}"}, 404
  new User({apikey: req.body.apikey}).save()
  User.findOne {apikey: req.body.apikey}, (err, user) ->
    return res.send {error: "User not found" }, 404 unless user?
    Box.findOne {name: req.params.box_name}, (err, box) ->
      if box
        res.send {error: "Box already exists"}
      else
        new Box({user: user._id, name: req.params.box_name}).save (err) ->
          if err
            console.log "Creating box: #{err} "
            res.send {error: "Unknown error"}
          else
            exports.unix_user_add req.params.box_name, (err, stdout, stderr) ->
              any_stderr = stderr is not ''
              console.log "Error adding user: #{err} #{stderr}" if err? or any_stderr
              res.send {error: "Sorry, couldn't create the box."} if err? or any_stderr
              res.send {status: "ok"}

# Add an SSH key to a box
app.post "/:box_name/sshkeys/?", (req, res) ->
  res.header('Content-Type', 'application/json')
  unless req.body.sshkey? then return res.send { error: "SSH Key not specified" }, 400

  Box.findOne {name: req.params.box_name}, (err, box) ->
    return res.send { error: "Box not found" }, 404 unless box?
    try
      name = SSHKey.extract_name req.body.sshkey
    catch TypeError
      return res.send { error: "SSH Key format not valid" }, 400
    unless name then return res.send { error: "SSH Key has no name" }, 400
    key = new SSHKey
      box: box._id
      name: name
      key: req.body.sshkey

    key.save ->
      SSHKey.find {box: box._id}, (err, sshkeys) ->
        keys_path = "/opt/cobalt/etc/sshkeys/#{box.name}/authorized_keys"

        keys = for key in sshkeys
          "#{key.key}"

        fs.writeFileSync keys_path, keys.join '\n', 'utf8'
        # Note: octal.  This is deliberate.
        fs.chmodSync keys_path, 0o600
        child_process.exec "chown #{box.name}: #{keys_path}" # insecure
        res.send {"status": "ok"}

app.listen process.env.COBALT_PORT

exports.unix_user_add = (box_name, callback) ->
  cmd = """
        cd /root/deployment-hooks && . lib/chroot_user &&
        create_user #{box_name} &&
        create_user_directories #{box_name} &&
        furnish_box #{box_name} &&
        mkdir /opt/cobalt/etc/sshkeys/#{box_name}
        """
  # insecure - sanitise box_name
  exec cmd, callback
