## The go-to HttpCtx handler for most use cases, when optimal performance is not critical. Parses request line and headers automatically.
##
## **Example:**
##
## .. code-block:: Nim
##
##    import cgi
##    import guildenstern/ctxfull
##
##    proc handleGet(ctx: HttpCtx, headers: StringTableRef) =
##      let htmlstart = "<!doctype html><title>GuildenStern FullCtx Example</title><body>request-URI: "
##      let htmlmore = "<br>user-agent: "
##      let htmllast = """<br><form action="/post" method="post"><input name="say" id="say" value="Hi"><button>Send"""
##      if not headers.hasKey("user-agent"): (ctx.reply(Http412); return)
##      var uri = ctx.getUri()
##      var useragent = headers.getOrDefault("user-agent")
##      let contentlength = htmlstart.len + uri.len + htmlmore.len + useragent.len + htmllast.len
##      if not ctx.replyStart(Http200, contentlength, htmlstart): return
##      if not ctx.replyMore(uri): return
##      if not ctx.replyMore(htmlmore): return
##      if not ctx.replyMore(useragent): return
##      ctx.replyLast(htmllast)
##
##    proc handlePost(ctx: HttpCtx) =
##      var html = "<!doctype html><title>GuildenStern FullCtx Example</title><body>You said: "
##      try:
##        html.add(readData(ctx.getBody()).getOrDefault("say"))
##        ctx.reply(Http200, html)
##      except: ctx.reply(Http412)
##
##    proc onRequest(ctx: HttpCtx, headers: StringTableRef) =
##      if ctx.isMethod("POST"): ctx.handlePost()
##      else: ctx.handleGet(headers)
##
##    var server = new GuildenServer
##    server.initFullCtx(onRequest, 5050)
##    echo "Point your browser to localhost:5050/any/request-uri/path/"
##    server.serve()

from posix import recv, SocketHandle
import strtabs
export strtabs
import httpcore
export httpcore

when not defined(nimdoc):
  import guildenstern
  export guildenstern
else:
  import guildenserver, ctxhttp


type
  FullRequestCallback* = proc(ctx: HttpCtx, headers: StringTableRef){.nimcall, raises: [].}


var
  requestCallback: FullRequestCallback
  ctx {.threadvar.}: HttpCtx
  headers {.threadvar.}: StringTableRef

const
  MSG_DONTWAIT = 0x40.cint

proc receiveHttp(): bool {.gcsafe, raises:[] .} =
  var expectedlength = MaxRequestLength + 1
  while true:
    if shuttingdown: return false
    let recvFlags = if ctx.requestlen == 0: MSG_DONTWAIT else: 0x00
    let ret = recv(posix.SocketHandle(ctx.socketdata.socket), addr request[ctx.requestlen], expectedlength - ctx.requestlen, recvFlags)
    if ctx.requestlen == 0 and ret == 0:
      # connection closed
      ctx.closeSocket()
      return false
    checkRet()
    let previouslen = ctx.requestlen
    ctx.requestlen += ret

    if ctx.requestlen >= MaxRequestLength:
      ctx.gs.notifyError("recvHttp: Max request size exceeded")
      ctx.closeSocket()
      return false

    if ctx.requestlen == expectedlength: break

    if not ctx.isHeaderreceived(previouslen, ctx.requestlen):
      if ctx.requestlen >= MaxHeaderLength:
        ctx.gs.notifyError("recvHttp: Max header size exceeded")
        ctx.closeSocket()
        return false
      continue

    let contentlength = ctx.getContentLength()
    if contentlength == 0: return true
    expectedlength = ctx.bodystart + contentlength
    if ctx.requestlen == expectedlength: break
  true


proc handleHttpRequest(gs: ptr GuildenServer, data: ptr SocketData) {.nimcall, raises: [].} =
  if ctx == nil: ctx = new HttpCtx
  if request.len < MaxRequestLength + 1: request = newString(MaxRequestLength + 1)
  if headers == nil: headers = newStringTable()
  initHttpCtx(ctx, gs, data)
  if receiveHttp() and ctx.parseRequestLine():
    headers.clear() # slow...
    ctx.parseHeaders(headers)
    {.gcsafe.}: requestCallback(ctx, headers)


proc initFullCtx*(gs: var GuildenServer, onrequestcallback: FullRequestCallback, port: int) =
  ## Initializes the fullctx handler for given ports with given request callback. See example above.
  {.gcsafe.}:
    requestCallback = onrequestcallback
    discard gs.registerHandler(handleHttpRequest, port)