fs          = require "fs"
Path        = require "path"
utils       = require "../utils"
IconService = require "./icon-service"
Minimatch   = require "minimatch"
ScanTask    = require.resolve "./scan-task"
Main        = require.resolve "../main"
$           = require("./debugging") __filename
{Task, CompositeDisposable, File} = require "atom"
{equal, isString} = utils


class Scanner
	
	# File extensions to skip when scanning file contents
	BINARY_FILES: /\.(exe|jpe?g|png|gif|bmp|py[co]|woff2?|ttf|ico|webp|zip|[tr]ar|gz|bz2)$/i
	
	# Minimum number of bytes needed to scan a file
	minScanLength: 6
	
	# Number of bytes to read from each file
	maxScanLength: 90
	
	
	# Symbol to store package-specific metadata in DOM elements
	metadata: Symbol "FileIconsMetadata"
	
	# Files that've already been scanned
	fileCache:   {}
	
	
	activate: ->
		$ "Activating"
		Main = require Main
		@directories = new Set
		@disposables = new CompositeDisposable
		@attribFiles = new Map
		
		@disposables.add IconService.onRequestScan (path) => @readFile path
		@disposables.add atom.project.onDidChangePaths => @update()
		@disposables.add atom.packages.onDidActivateInitialPackages =>
			@waitForTree() unless @findTreeView()
			@update()
	
	# Clear up memory when deactivating package
	destroy: ->
		$ "Destroyed"
		@disposables.dispose()
		@directories.clear()
	
	
	# Store a link to the tree-view element the next time it's opened
	waitForTree: ->
		return if @treeViewEl
		$ "Waiting for tree-view"
		
		@disposables.add @onToggled = atom.commands.onDidDispatch (event) =>
			
			# Tree-view opened
			if event.type is "tree-view:toggle"
				$ "Tree-view toggled"
				
				@findTreeView()
				@update()
				IconService.queueRefresh()
				
				# Unsubscribe now that we're on the same page
				@disposables.remove @onToggled
				@onToggled.dispose()
		
	
	
	# Locate the tree-view element in the workspace
	findTreeView: ->
		@treeView   ?= atom.packages.loadedPackages["tree-view"].mainModule
		@treeViewEl ?= @treeView?.treeView
		return unless @treeViewEl? and @treeViewEl.onEntryMoved?
		
		# Called when renaming/moving files between directories
		@disposables.add @treeViewEl.onEntryMoved (info) =>
			$ "File moved in tree-view", info
			{oldPath, newPath} = info
			IconService.changeFilePath oldPath, newPath
			
			# Transfer overridden-grammars when moving files
			if scope = atom.grammars.grammarOverridesByPath[oldPath]
				$ "Transferring user-assigned grammar", {info, scope}
				atom.grammars.setGrammarOverrideForPath newPath, scope
				atom.grammars.clearGrammarOverrideForPath oldPath
				delete IconService.fileCache[oldPath]
				delete IconService.fileCache[newPath]
			IconService.queueRefresh()
				
		
		# Called when user deletes a file from the tree-view
		@disposables.add @treeViewEl.onEntryDeleted (info) =>
			$ "Purging cache of deleted file", info
			{path} = info
			for file of @fileCache when file?.path is path
				delete @fileCache[file]
			delete IconService.headerCache[path]
	
	
	# Reparse the tree-view for newly-added directories
	update: ->
		if @treeViewEl
			$ "Updating"
			for i in @treeViewEl.find ".directory.entry"
				@add(i) unless @directories.has(i)
		
		else $ "Unable to update; tree-view not found"


	# Register a directory instance in the Scanner's directories list
	# - item: A tree-view entry representing a directory
	add: (item) ->
		$ "Directory added", item
		@directories.add(item)
		dir            = item.directory
		onExpand       = dir.onDidExpand     => @readFolder dir, item
		onCollapse     = dir.onDidCollapse   => setTimeout (=> @prune()), 0
		onEntriesAdded = dir.onDidAddEntries @checkEntries
		dir[@metadata] = {onExpand, onEntriesAdded, onCollapse}
		@disposables.add onExpand, onEntriesAdded, onCollapse
		
		# Trigger callbacks
		isOpened = dir.expansionState.isExpanded
		@onAddFolder(dir, item)
		@readFolder(dir, item) if isOpened


	# Remove stored references to detached directory-views
	prune: ->
		remove = []
		@directories.forEach (dir) =>
			remove.push(dir) unless document.body.contains(dir)
		
		for i in remove
			metadata = i.directory[@metadata]
			@disposables.remove metadata.onExpand
			@disposables.remove metadata.onEntriesAdded
			@disposables.remove metadata.onCollapse
			@directories.delete(i)


	# Parse the contents of a newly-added/opened directory
	readFolder: (dir, item) ->
		
		# Check if we need to scan any files
		if Main.checkHashbangs or Main.checkModelines
			$ "Reading directory", dir, item
			
			files = []
			
			# Scan each item for hashbangs/modelines
			for name, entry of dir.entries
				if @shouldScan entry then files.push entry
			
			# If there's at least one file to scan, go for it
			if files.length
				$ "Scanning files", files
				task = Task.once ScanTask, files
				task.on "file-scan", (data) -> IconService.checkFileHeader data
		
		# Check for .gitattributes files if needed
		if Main.useGitAttrib
			for name, entry of dir.entries when name is ".gitattributes"
				@readGitAttributes entry.realPath
	
		@update()
	

	# Scan a single file for headers. Used when directory lists aren't available.
	readFile: (path) ->
		return unless Main.checkHashbangs or Main.checkModelines
		file = @dupeFileObject path
		if @shouldScan file
			$ "Reading file", file
			task = Task.once ScanTask, [file]
			task.on "file-scan", (data) ->
				IconService.checkFileHeader data
				IconService.queueRefresh()
	
	
	
	# Scan the contents of a .gitattributes file for "linguist-language" rules
	readGitAttributes: (path) ->
		if @attribFiles.has(path)
			$ "Already tracking .gitattributes", path
			return
		
		setTimeout (=>
			$ "Found .gitattributes"
			@attribFiles.set path, file = new File(path)
			
			file.onDidRename =>
				$ ".gitattributes moved", file
				@attribFiles.delete path
				@attribFiles.set path = file.realPath || file.path, file
			
			file.onDidDelete =>
				$ ".gitattributes deleted", file
				rules     = IconService.attributeRules
				ruleCount = rules.length
				rules     = rules.filter (rule) -> rule.path isnt path
				@attribFiles.delete path
				$ "Rules deleted: #{rules.length - ruleCount}"
				IconService.attributeRules = rules
			
			# Search for "linguist-language" attributes in the file
			file.data = fs.readFileSync(path).toString()
			pattern   = /^(.*?)\s+linguist-language=(.*)$/gmi
			while match = pattern.exec(file.data)
				[line, glob, language] = match
				
				unless icon = IconService.iconMatchForLanguage(language)
					$ "Unrecognised language: #{language}"
					continue
				
				filePath = Path.resolve Path.dirname(path), glob
				matcher  = new Minimatch.Minimatch filePath
				rule     = {path: filePath, icon, language, matcher}
				IconService.attributeRules.push rule
				$ "Added override: #{language} (#{glob})", rule
			
			@applyGitAttributes()
		), 1
	
	
	# Modify cached paths that fall under an affected attribute glob
	applyGitAttributes: ->
		$ "Applying .gitattributes"
		shouldRefresh = false
		paths = Object.keys(IconService.fileCache)
		for rule in IconService.attributeRules
			for affectedPath in (paths.filter (path) => rule.matcher.match(path))
				delete IconService.fileCache[affectedPath]
				shouldRefresh = true
		IconService.queueRefresh() if shouldRefresh
	
	
	# Check the newly-added contents of a directory
	checkEntries: (items) =>
		shouldRefresh = false
		
		# Cycle through each entry, skipping directories
		for file in items when not file.expansionState?
			shouldRefresh = true if @hasMoved(file)
	
		@update()
		IconService.refresh() if shouldRefresh
	
	
	# Update cached headers if a file's path has changed
	hasMoved: (file) ->
		{dev, ino} = file.stats || fs.statSync(file)
		guid = ino
		guid = dev + "_" + guid if dev
		
		# Has this file been moved to a different directory?
		if (cached = @fileCache[guid]) and cached.path isnt file.path
			$ "File moved", {file, guid}
			IconService.changeFilePath cached.path, file.path 
			cached.path = file.path
			true
		else false
	
	
	# Check whether a file's data should be scanned
	shouldScan: (file) ->
		
		# No stats? Bail, this isn't right
		return false unless file.stats?
		
		# Skip directories
		return false if file.expansionState?
		
		# Skip symbolic links
		if file.symlink
			$ "Skipping file (Symlink)", file
			return false
		
		{ino, dev, size, ctime, mtime} = file.stats
		{path} = file
		size ?= 0
		
		
		# Skip files that're too small
		if size < @minScanLength
			$ "Skipping file (#{size} bytes)", file
			return false
		
		
		# Skip anything that's obviously binary
		if @BINARY_FILES.test file.name
			$ "Skipping file (Binary)", file
			return false
		
		
		# If we have access to inodes, use it to build a GUID
		if ino
			guid = ino
			guid = dev + "_" + guid if dev
		
		# Otherwise, use the filesystem path instead, which is less reliable
		else guid = path
		
		
		stats = {ino, dev, size, ctime, mtime}
		
		# This file's been scanned, and it hasn't changed
		if equal stats, @fileCache[guid]?.stats
			$ "Already scanned; file unchanged", file, stats, @fileCache[guid]
			return false
		
		
		# Burn any cached entries with the same path
		for key, value of @fileCache
			if value.path is path
				$ "Deleting stale path", {path, deleted: @fileCache[key]}
				delete @fileCache[key]
		
		# Record the file's state to avoid pointless rescanning
		@fileCache[guid] = {path, stats}
		$ "Marking file as scanned", path, "guid: #{guid}", stats
		
		true
	
	
	
	# Scan the first couple lines of a file. Used by scan-task.coffee
	scanFile: (file, length = @maxScanLength) ->
		
		new Promise (resolve, reject) ->
			fd = fs.openSync file.realPath || file.path, "r"
			
			# Future-proof way to create a buffer (added in Node v5.1.0).
			# TODO: Replace with simply "Buffer.alloc(length)" once Atom supports it
			buffer = if Buffer.alloc? then Buffer.alloc(length) else new Buffer(length)
			
			# Read the first chunk of the file
			bytes = fs.readSync fd, buffer, 0, length, 0
			fs.closeSync fd
			data = buffer.toString()
			
			# Strip null-bytes padding short file-chunks
			if(bytes < data.length)
				data = data.replace /\x00+$/, ""
			
			# If the data contains null bytes, it's likely binary. Skip.
			unless /\x00/.test data
				emit "file-scan", {data, file}
			resolve data


	# Read and store file-stats in an object resembling a File instance.
	# Used when passing filepaths to methods that expect a File object.
	dupeFileObject: (path) ->
		
		# NOTE: This class is NOT the same "File" class used by tree-view. Partly
		# similar, but the latter has properties which this package relies on more.
		file = new File(path)
		
		# Fill in the blanks
		file.expansionState = false if file.isDirectory()
		file.name     = file.getBaseName()
		file.realPath = file.getRealPathSync()
		file.stats    = fs.statSync path
		
		file
		

module.exports = new Scanner
