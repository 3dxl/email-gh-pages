fs        = require 'fs'
RSVP      = require 'rsvp'
throttle  = require 'rsvp-throttle'
github    = require 'octonode'
Queue     = require 'bull'
YAML      = require 'js-yaml'
moment    = require 'moment'
sharp     = require 'sharp' # used for resizing images
imageinfo = require 'imageinfo'

queueName = 'inbound-email-www.3dxl.nl'
repoName  = '3dxl/flaming-spice'

# make sure these files exist!
githubCredentials = JSON.parse fs.readFileSync 'credentials_github.json', 'ascii'
redisCredentials = JSON.parse fs.readFileSync 'credentials_redis.json', 'ascii'

# authenticate and build the promisified repo object
repo = github.client(githubCredentials).repo repoName
for method in ['contents', 'createContents', 'updateContents']
  repo[method] = RSVP.denodeify repo[method], ['data','headers']

# init the queue
queue = Queue queueName, redisCredentials.port, redisCredentials.host
console.log 'Will process jobs in', queueName

# save to github, returns a fixed URL to the file if succesful
sendToGithub = throttle 1, (path, buffer) ->
  repo.createContents(path, "Automatic upload of photo", buffer)
  .then ({data,headers}) -> data.content.html_url.replace('github.com', 'raw.githubusercontent.com').replace('/blob/', '/')

slugify = (text) -> # from https://gist.github.com/mathewbyrne/1280286
  text.toString().toLowerCase()
    .replace(/\s+/g, '-')           # Replace spaces with -
    .replace(/[^\w\-]+/g, '')       # Remove all non-word chars
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
  photos = repo.contents(photoFolder)
    .then ({data,headers}) ->
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

      transfers = email.attachments?.map (attachment) ->
        path = photoFolder + '/' + ('00' + availableIndex++).slice(-2) + '_' + attachment.fileName
        buffer = new Buffer(attachment.content, 'base64')

        parts = path.split('.')
        parts[parts.length] = parts[parts.length - 1]
        parts[parts.length - 2] = 'mini'
        path256 = parts.join('.')
        parts[parts.length - 2] = 'midi'
        path1024 = parts.join('.')
        parts[parts.length - 2] = 'orig'
        path = parts.join('.')

        deferred = RSVP.defer()

        # resize to bounding box, based on aspect ratio
        info = imageinfo buffer
        if info.width / info.height >= 4/3
          width = 1024
          height = null
        else
          width = null
          height = 768

        sharp(buffer).resize((width || 0) >> 2, (height || 0) >> 2).toBuffer (err, buffer256) ->
          return deferred.reject err if err
          sharp(buffer).resize(width, height).toBuffer (err, buffer1024) ->
            return deferred.reject err if err

            sendToGithub(path256, buffer256)
            .then -> sendToGithub(path, buffer)
            .then -> sendToGithub(path1024, buffer1024)
            .then (midiName) ->
              console.log '  -  Resized', midiName
              deferred.resolve midiName

        deferred.promise

      RSVP.all(transfers || [])

  # fetch the blog post from github
  post = repo.contents(postPath)
    .then ({data,headers}) ->
      console.log '  -  Will append to existing post'
      text: (new Buffer(data.content, 'base64')).toString()
      sha: data.sha
    .catch (err) ->
      console.log '  -  Will create a new post'
      text: null
      sha: null

  # write all new
  RSVP.hash(photos: photos, post: post)
  .then ({photos, post}) ->
    # photos is a list of http urls to all uploaded images
    postChunks = post.text?.split('---\n') || []

    if postChunks[0] == ''
      # existing post
      postChunks = postChunks.slice(1)
      frontMatter = YAML.load postChunks[0]
    else
      # new post
      frontMatter =
        layout: 'post'
        published: true
      postChunks = ['']

    # add title
    if target == 'timeline'
      frontMatter.title ?= 'Timeline for ' + moment(email.serverReceived).format('dddd Do of MMM YYYY')
      frontMatter.categories ?= []
      frontMatter.categories.push 'timeline' if frontMatter.categories.indexOf('timeline') == -1
    else
      frontMatter.title ?= slugify(target).split('-').map((part) -> part.charAt(0).toUpperCase() + part.slice(1)).join(' ')

    # add author
    if email.from[0]?.name?.length > 0
      frontMatter.authors ?= []
      frontMatter.authors.push email.from[0].name if frontMatter.authors.indexOf(email.from[0].name) == -1

    console.log '  -  FrontMatter:'
    console.log YAML.dump frontMatter

    postChunks[0] = YAML.dump(frontMatter)

    # add a header
    text = '## '
    text += moment(email.serverReceived).format('HH:mm') + ' ' if target == 'timeline'
    text += email.subject
    text += '\n'

    # add photos
    for url in photos
      text += '![' + url.split('/').slice(-1)[0] + '](' + url + ')\n'
    text += '\n' if photos.length

    # add text
    text += (email.text || '')
      .replace('Verzonden vanaf Samsung Mobile', '')

    console.log '  -  Appended text:'
    console.log text

    postChunks.push text
    post.text = '---\n' + postChunks.map((chunk) -> chunk.replace(/^\n+|\n+$/g, '')).join('\n\n---\n\n')

    # store the new post
    if post.sha
      repo.updateContents postPath, 'Automatic message updated from email', post.text, post.sha
    else
      repo.createContents postPath, 'Automatic message created from email', post.text
  .then ({data,headers}) ->
    # console.log data
    # console.log headers

    millis = (new Date()).valueOf() - startTime
    console.log 'Finished processing job', msg.jobId, 'in', millis, 'ms'

    console.log headers['x-ratelimit-remaining'], '/', headers['x-ratelimit-limit'], 'expires', moment(1000*parseInt(headers['x-ratelimit-reset'])).format()
    done()
  .catch (err) ->
    console.log '==Failed== processing job', msg.jobId, err
    done err

