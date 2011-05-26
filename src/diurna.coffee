
fs         = require "fs"
path       = require "path"
util       = require "util"
markdown   = require "markdown"
eco        = require "eco"
stylus     = require "stylus"
stitch     = require "stitch"
formatDate = require "dateformat"
_          = require "underscore"

_verbosity = 0

RESERVED_NAMES = [
  "styles"
  "scripts"
  "404.eco"
]

exports.build = (from, to, verbosity) ->
  _verbosity = verbosity if verbosity

  scripts = path.join(from, "scripts")
  styles = path.join(from, "styles", "main.styl")

  path.exists scripts, (exists) ->
    buildScripts scripts, path.join(to, "scripts", "main.js") if exists

  path.exists styles, (exists) ->
    buildStyles styles, path.join(to, "styles", "main.css") if exists

  buildPages from, to

slugify = (str) ->
  replaces =
    'a': /[åäàáâ]/g
    'c': /ç/g
    'e': /[éèëê]/g
    'i': /[ìíïî]/g
    'u': /[üû]/g
    'o': /[öô]/g
    '-': new RegExp ' ', 'g'

  slug = str.toLowerCase()
  slug = slug.replace(regex, replacement) for replacement, regex of replaces

  slug.replace /[^\w-\.]/g, ''

buildPages = (from, to) ->
  # Parse the title from a filename, meaning strip any leading numbers,
  # if followed by period or dash.
  #
  # > parseTitle("1. My cool blog post")
  # My cool blog post
  # > parseTitle("1 My cool blog post")
  # 1 My cool blog post
  parseTitle = (filename) ->
    re = /^(?:\d+\s*(?:\.|-)\s*)?(.*)/
    filename.match(re)[1]

  filenames = (basename) ->
    if basename is "index"
      index: "index.html"
      content: "content.html"
    #else if ".include" in basename
    #  "#{basename.replace(".include", "")}.html"
    else
      index: "#{basename}/index.html"
      content: "#{basename}/content.html"

  createNode = (parent, file) ->
    node = parent.files[file] = {}
    node.title = parseTitle path.basename(file, path.extname(file))
    node.name = slugify(node.title)
    node.path = path.join parent.path, node.name
    node.filePath = path.join parent.filePath, file
    return node

  traverse = (options, parent) ->
    options.root ?= parent
    currentDir = path.join(options.baseDir, parent.filePath)

    fs.readdir currentDir, (err, files) ->
      return util.error err if err

      pages = {}
      dirNames = []

      for file in files when file not in RESERVED_NAMES
        filePath = path.join(currentDir, file)

        node = createNode(parent, file)
        extension = path.extname(file)
        stat = fs.statSync(filePath)
        node.ctime = stat.ctime
        node.mtime = stat.mtime

        if stat.isDirectory()
          node.type = "directory"
          node.files = []
          dirNames.push node
        else if file is "layout.eco"
          parent.layouts ?= []
          parent.layouts.push filePath
        else if file.match /\.include\./
          node.type = "include"
          parent.includes ?= []
          parent.includes.push file
        else if extension is ".md"
          node.type = if file is "index.md" then "index" else "page"
          pages[filePath] = node
        else if extension is ".eco"
          node.type = "layout"
        else
          src = filePath
          dst = path.join(options.outDir, parent.path, file)

          path.exists dst, (exists) ->
            if not exists
              mkdirs path.dirname(dst)
              fs.link src, dst, (err) ->
                return util.error err if err
                log "Linked from #{src} to #{dst}"

      for page, node of pages
        basename = path.basename(page, ".md")
        layouts = if parent.layouts then [].concat parent.layouts else []
        pageLayout = path.join(currentDir, "#{basename}.eco")
        layouts.push pageLayout if path.existsSync pageLayout
        context = {}
        _.extend context, node
        _.extend context,
          parent: parent
          root: options.root

        buildPage
          body: markdown.parse read(page)
          directory: path.join(options.outDir, parent.path)
          layouts: layouts
          filenames: filenames(node.name)
          context: context

      for node in dirNames
        node.layouts = parent.layouts
        traverse options, node

  root =
    name: "__root__"
    path: ""
    files: []

  traverse
    baseDir: from
    outDir: to
  , root

getLayout = _.memoize (layout) -> require layout

buildPage = (options) ->
  helpers =
    nav: (root) -> (node for key, node of root.files when node.type in ["directory", "page"])
    include: (file) -> read path.join(options.directory, file)
    formatDate: formatDate
    humanDate: (date) ->
      day = 24 * 60 * 60 * 1000
      diff = new Date() - date
      format = if diff < day then "HH:MM" else "yyyy-mm-dd HH:MM"
      formatDate date, format

  render = (layouts, body) ->
    return body unless layouts.length

    context = {}
    _.extend context, options.context
    _.extend context, helpers
    context.dirs = helpers.nav(context.root)
    context.siblings = helpers.nav(context.parent)
    context.body = body if body?

    [remainingLayouts..., layout] = layouts
    render remainingLayouts, getLayout(layout)(context)

  html = render options.layouts, options.body

  write path.join(options.directory, options.filenames.content), options.body, (err) ->
    return util.error if err

  write path.join(options.directory, options.filenames.index), html, (err) ->
    return util.error if err

buildScripts = (from, to) ->
  package = stitch.createPackage paths: [ from ]

  package.compile (err, source) ->
    return util.error err if err

    write to, source, (err) ->
      return util.error err if err

buildStyles = (from, to) ->
  fs.readFile from, "utf8", (err, str) ->
    return util.error err if err

    stylus(str)
      .set("filename", from)
      .use(require("nib")())
      .import("nib")
      .render (err, css) ->
        return util.error err if err

        write to, css, (err) ->
          return util.error err if err

read = _.memoize (file) ->
  try
    fs.readFileSync file, "utf8"
  catch e
    util.error "Missing file: #{file}"

write = (file, str, next) ->
  path.exists file, (exists) ->
    mkdirs path.dirname(file) unless exists
    
    log "Writing file #{file}"
    fs.writeFile file, str, next

mkdirs = (pathName) ->
  base = ""
  for dir in pathName.split("/")
    base += "#{dir}/"

    unless path.existsSync base
      log "Creating directory #{base}"
      fs.mkdirSync base, 0755

log = ->
  console.log.apply null, arguments if _verbosity

