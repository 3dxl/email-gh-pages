fs = require 'fs'
RSVP = require 'rsvp'
github = require 'octonode'

sourceImage = '/Users/sjoerd/Desktop/foto.JPG'

readFile = RSVP.denodeify(fs.readFile)

repo = null
todaysFolder = 'photos/' + (new Date()).toISOString().substr(0,10)
targetPath = null

# authenticate and build the promisified repo object
readFile('github_authentication.json', 'ascii')
.then (authJson) ->
  github.client JSON.parse authJson
.then (client) ->
  repo = client.repo '3dxl/3dxl.github.io'
  for method in ['info', 'contents', 'createContents']
    repo[method] = RSVP.denodeify repo[method], ['data','headers']

# read contents of repo to get a free index
.then ->
  repo.contents(todaysFolder)
  .then ({data,headers}) ->
    maxIndex = Math.max.apply null, data.map (file) ->
      if isNaN parseInt file.name then -1 else parseInt file.name
    Math.max maxIndex + 1, 0
  .catch (err) -> # folder does not exist
    0
.then (availableIndex) ->
  targetPath = todaysFolder + '/' + availableIndex + '.jpg'

# read the image and store it in today photos folder
  readFile sourceImage
.then (data) ->
  message = 'Photo added from email message'
  repo.createContents targetPath, message, data
.then ({data,headers}) ->
  console.log JSON.stringify(data, null, '  ')
.catch (err) ->
  console.log 'ERR', err