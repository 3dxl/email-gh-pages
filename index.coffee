fs        = require 'fs'
RSVP      = require 'rsvp'
throttle  = require 'rsvp-throttle'
Queue     = require 'bull'
YAML      = require 'js-yaml'
moment    = require 'moment'
gm        = require 'gm' # used for resizing images
Octokit   = require 'octokit'

queueName = 'inbound-email-website.3dxl.nl'
targetRepo = username: '3dxl', reponame: '3dxl.github.io'
githubURLPrefix = 'https://raw.githubusercontent.com/3dxl/3dxl.github.io/master/'

# make sure these files exist!
githubCredentials = JSON.parse fs.readFileSync __dirname + '/credentials_github.json', 'ascii'
redisCredentials = JSON.parse fs.readFileSync __dirname + '/credentials_redis.json', 'ascii'

# authenticate and build the promisified repo object
gh = Octokit.new githubCredentials
repo = gh.getRepo targetRepo.username, targetRepo.reponame
repoBranch = repo.getBranch() # get default branch

# init the queue
queue = Queue queueName, redisCredentials.port, redisCredentials.host
console.log 'Will process jobs appearing in queue:', queueName

# returns a promise to a resized buffer
resizeBuffer = throttle 1, (buffer, name, width, height) ->
  new RSVP.Promise (res, rej) ->
    gm(buffer, name)
    .resize(width, height, '>').autoOrient().quality(80)
    .toBuffer (err, resizedBuffer) ->
      return rej err if err
      res resizedBuffer

slugify = (text) -> # from https://gist.github.com/mathewbyrne/1280286
  text.toString().toLowerCase()
    .replace(/\s+/g, '-')           # Replace spaces with -
    .replace(/[^\w\-]+/g, '-')       # Remove all non-word chars
    .replace(/\-\-+/g, '-')         # Replace multiple - with single -
    .replace(/^-+/, '')             # Trim - from start of text
    .replace(/-+$/, '')             # Trim - from end of text

# manage failed jobs on start
queue.getFailed().then (failedJobs) ->
  if failedJobs?.length
    console.log 'Removing failed jobs since last start', failedJobs.map (job) -> job.jobId
    job.remove() for job in failedJobs || []

# start listening to jobs
queue.process (msg, done) ->
  email = msg.data
  startTime = (new Date()).valueOf()

  console.log 'Started processing', msg.jobId, email.subject

  isoDate = email.serverReceived.substr 0, 10
  target = email.to[0]?.address?.split('@')[0] || 'timeline'
  postPath = '_posts/' + isoDate + '-' + slugify(target) + '.markdown'
  photoFolder = 'photos/' + isoDate

  # read contents of repo to get find a free index and add photos to the repo
  repoBranch.contents(photoFolder)
  .then (data) ->
    data = JSON.parse data if typeof data == 'string'
    maxIndex = Math.max.apply null, data.map (file) ->
      if isNaN parseInt file.name then -1 else parseInt file.name
    console.log '  - ', photoFolder, 'maxIndex is', maxIndex
    Math.max maxIndex + 1, 0
  .catch (err) -> # folder does not exist
    console.log '  - ', 'Will create', photoFolder
    0
  .then (availableIndex) ->
    # process each attachment and send it to github
    path = null
    buffer = null

    commitContents = {}

    email.attachments?.forEach (attachment) ->
      console.log '  -  Will resize', attachment.fileName
      path = photoFolder + '/' + ('00' + availableIndex++).slice(-2) + '_' + attachment.fileName
      buffer = new Buffer(attachment.content, 'base64')

      # create path with 'mini', 'midi', 'orig' in front of the extension
      # eg 'sample.jpg' -> 'sample.mini.jpg'
      parts = path.toLowerCase().split('.')
      parts[parts.length] = parts[parts.length - 1]

      # add a thumb
      parts[parts.length - 2] = 'mini'
      commitContents[parts.join('.')] = resizeBuffer(buffer, attachment.fileName, 256, 192).then (resizedBuffer) ->
        return isBase64: true, content: resizedBuffer.toString 'binary'

      # add a normal image
      parts[parts.length - 2] = 'midi'
      commitContents[parts.join('.')] = resizeBuffer(buffer, attachment.fileName, 1024, 768).then (resizedBuffer) ->
        return isBase64: true, content: resizedBuffer.toString 'binary'

      # add original
      parts[parts.length - 2] = 'orig'
      commitContents[parts.join('.')] = isBase64: true, content: buffer.toString 'binary'

    commitContents[postPath] = repoBranch.contents(postPath).catch (err) ->
        console.log '  -  Will create a new post'
        null

    RSVP.hash commitContents
  .then (commitContents) ->
    isNewPost = false

    postChunks = commitContents[postPath]?.split('---\n') || []

    if postChunks[0] == ''
      # existing post
      postChunks = postChunks.slice(1)
      frontMatter = YAML.load postChunks[0]
    else
      # new post
      isNewPost = true
      frontMatter =
        layout: 'post'
        published: true
      postChunks = ['']

    # add title and category
    if target == 'timeline'
      frontMatter.title ?= 'Timeline for ' + moment(email.serverReceived).format('dddd')
    else
      frontMatter.title ?= email.subject

    frontMatter.categories ?= []
    frontMatter.categories.push slugify(target) if frontMatter.categories.indexOf(slugify(target)) == -1

    # add author
    if email.from[0]?.name?.length > 0
      frontMatter.authors ?= []
      frontMatter.authors.push email.from[0].name if frontMatter.authors.indexOf(email.from[0].name) == -1

    miniPhotos = Object.keys(commitContents).filter((k) -> k.indexOf('.mini.') > -1)
    frontMatter.thumbnail ?= githubURLPrefix + miniPhotos[0] if miniPhotos.length > 0

    console.log '  -  FrontMatter:'
    console.log YAML.dump frontMatter

    postChunks[0] = YAML.dump(frontMatter)

    text = ''

    # add a header
    if !isNewPost || (target == 'timeline')
      text += '## '
      text += moment(email.serverReceived).format('HH:mm') + ' ' if target == 'timeline'
      text += email.subject
      text += '\n'

    # add photos
    midiPhotos = Object.keys(commitContents).filter((k) -> k.indexOf('.midi.') > -1)
    for path in midiPhotos
      text += '![](' + githubURLPrefix + path + ')\n'
    text += '\n' if Object.keys(commitContents).length > 1

    # add text
    text += (email.text || '')
      .replace('Verzonden vanaf Samsung Mobile', '')

    console.log '  -  Appended text:'
    console.log text

    postChunks.push text
    commitContents[postPath] = '---\n' + postChunks.map((chunk) -> chunk.replace(/^\n+|\n+$/g, '')).join('\n\n---\n\n')

    # store the new post
    repoBranch.writeMany commitContents, 'Update by email ' + email.from[0]?.name + ' <' + email.from[0]?.email + '>'
  .then (result) ->
    console.log '  -  Wrote message to Github', result.url

    millis = (new Date()).valueOf() - startTime
    console.log 'Finished processing job', msg.jobId, 'in', millis, 'ms'

    done()
  .catch (err) ->
    console.log '==Failed== processing job', msg.jobId, err
    done err

