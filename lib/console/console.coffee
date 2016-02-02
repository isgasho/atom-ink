# TODO: autocomplete

{Emitter, CompositeDisposable} = require 'atom'
ConsoleView = require './view'
HistoryProvider = require './history'

module.exports =
class Console
  @activate: ->
    @subs = new CompositeDisposable
    @subs.add atom.commands.add 'ink-console atom-text-editor:not([mini])',
      'console:evaluate': ->
        ed = @getModel()
        ed.inkConsole.eval ed
      'core:move-up': (e) ->
        ed = @getModel()
        ed.inkConsole.keyUp e, ed
      'core:move-down': (e) ->
        ed = @getModel()
        ed.inkConsole.keyDown e, ed
      'core:move-left': (e) ->
        delete @getModel().inkConsole.prefix
      'core:move-right': (e) ->
        delete @getModel().inkConsole.prefix
      'core:backspace': (e) ->
        @getModel().inkConsole.cancelMode e

    @subs.add atom.commands.add 'ink-console',
      'core:copy': ->
        if (sel = document.getSelection().toString())
          atom.clipboard.write sel
      'console:previous-in-history': -> @getModel().previous()
      'console:next-in-history': -> @getModel().next()

  @deactivate: ->
    @subs.dispose()

  constructor: ->
    @items = []
    @history = new HistoryProvider
    @emitter = new Emitter
    # TODO: we shouldn't need to know about the view at all
    @view = new ConsoleView().initialize @
    @input()

  # Basic item / input logic

  push: (cell) ->
    @items.push cell
    @emitter.emit 'did-add-item', cell

  onDidAddItem: (f) -> @emitter.on 'did-add-item', f

  clear: (cell) ->
    @items = []
    @emitter.emit 'did-clear'

  onDidClear: (f) -> @emitter.on 'did-clear', f

  getInput: ->
    last = @items[@items.length-1]
    if last?.input then last

  input: ->
    delete @prefix
    if not @getInput()
      @push type: 'input', icon: 'chevron-right', input: true
      @focusInput()

  done: ->
    if @getInput()
      @view.focus() if @view.hasFocus() # Defocus input
      @getInput().input = false

  reset: ->
    @done()
    @clear()
    @input()

  eval: (ed) ->
    if (input = @getInput()?.view.getModel())
      if ed == input
        @emitter.emit 'eval', ed
      else
        input.setText ed.getText()
        @focusInput()
        @view.scroll()

  onEval: (f) -> @emitter.on 'eval', f

  openInTab: ->
    p = atom.workspace.getActivePane()
    if p.items.length > 0
      p = p.splitDown()
      p.setFlexScale 1/2
    p.activateItem @view
    p.onDidActivate => setTimeout =>
      if document.activeElement == @view
          @focusInput()

  toggle: ->
    if atom.workspace.getPaneItems().indexOf(@view) > -1
      @view.parentElement.parentElement.getModel().removeItem @view
    else
      @openInTab()
      @focusInput()

  focusInput: ->
    if @getInput()?
      @view.focusVisible @getInput().view

  # Output

  @debounce: (t, f) ->
    timeout = null
    (args...) ->
      if timeout? then clearTimeout timeout
      timeout = setTimeout (=> f.call this, args...), t

  @buffer: (f) ->
    buffer = []
    flush = @debounce 10, ->
      f.call this, buffer.join('').trim()
      buffer = []
    (s) ->
      buffer.push(s)
      flush.call this

  out: @buffer (s) -> @push type: 'out', value: s

  err: @buffer (s) -> @view.add(@view.errView(s))

  info: @buffer (s) -> @view.add(@view.infoView(s))

  result: (r, opts) -> @view.add(@view.resultView(r, opts))

  # Input Modes

  modes: -> {}

  defaultMode: ->
    for char, mode of @modes()
      if char is 'default'
        return mode

  modeByName: (name) ->
    for char, mode of @modes()
      return mode if mode.name is name

  cursorAtBeginning: (ed) ->
    ed.getCursors().length == 1 and
    ed.getCursors()[0].getBufferPosition().isEqual [0, 0]

  setMode: (cell, mode) ->
    ed = cell.querySelector('atom-text-editor').getModel()
    if mode?.constructor is String then mode = @modeByName(mode)
    mode ?= @defaultMode()
    if not mode
      delete ed.inkConsoleMode
      if @view.defaultGrammar then ed.setGrammar @view.defaultGrammar
      @view.setIcon cell, 'chevron-right'
    else
      ed.inkConsoleMode = mode
      if mode.grammar then ed.setGrammar mode.grammar
      @view.setIcon cell, mode.icon or 'chevron-right'

  watchModes: (cell) ->
    @edListener?.dispose()
    ed = cell.querySelector('atom-text-editor').getModel()
    @edListener = ed.onWillInsertText (e) =>
      if (mode = @modes()[e.text]) and @cursorAtBeginning(ed) and ed.inkConsoleMode isnt mode
        e.cancel()
        @setMode cell, mode

  cancelMode: (e) ->
    ed = e.currentTarget.getModel()
    cell = e.currentTarget.parentElement.parentElement
    if @cursorAtBeginning(ed) and ed.inkConsoleMode
      @setMode cell

  # History

  logInput: ->
    ed = @getInput().view.getModel()
    input = ed.getText()
    mode = ed.inkConsoleMode
    @history.push
      input: input
      mode: mode?.name

  moveHistory: (up) ->
    ed = @getInput().view.getModel()
    if ed.getText() or not @prefix?
      pos = ed.getCursorBufferPosition()
      text = ed.getTextInRange [[0,0], pos]
      @prefix = {pos, text}
    next = if up
      @history.getPrevious @prefix.text
    else
      @history.getNext @prefix.text
    ed.setText next.input
    # @setMode @view.getInput(), next.mode
    ed.setCursorBufferPosition @prefix.pos or [0, 0]

  previous: -> @moveHistory true
  next: -> @moveHistory false

  keyUp: (e, ed) ->
    if ed == @getInput()?.view.getModel()
      curs = ed.getCursorsOrderedByBufferPosition()
      if curs.length is 1 and (@prefix? or curs[0].getBufferRow() == 0)
        e.stopImmediatePropagation()
        @previous()

  keyDown: (e, ed) ->
    if ed == @getInput()?.view.getModel()
      curs = ed.getCursorsOrderedByBufferPosition()
      if curs.length is 1 and (@prefix? or curs[0].getBufferRow()+1 == ed.getLineCount())
        e.stopImmediatePropagation()
        @next()
