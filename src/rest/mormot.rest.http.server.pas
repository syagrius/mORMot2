/// REpresentation State Tranfer (REST) HTTP Server
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.rest.http.server;

{
  *****************************************************************************

   Server-Side REST Process over HTTP/WebSockets
    - TRestHttpServer RESTful Server
    - TRestHttpRemoteLogServer to Receive Remote Log Stream

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  variants,
  contnrs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.buffers,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.datetime,
  mormot.core.variants,
  mormot.core.data,
  mormot.core.rtti,
  mormot.crypt.core,
  mormot.core.json,
  mormot.core.threads,
  mormot.core.perf,
  mormot.core.search, // for fAccessControlAllowOriginsMatch
  mormot.crypt.secure,
  mormot.core.log,
  mormot.core.interfaces,
  mormot.core.zip,
  mormot.orm.base,
  mormot.orm.core,
  mormot.orm.rest,
  mormot.soa.core,
  mormot.soa.server,
  mormot.db.core,
  mormot.rest.core,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.net.sock,
  mormot.net.http,
  mormot.net.server,
  mormot.net.async,
  mormot.net.ws.core,
  mormot.net.ws.server,
  mormot.net.ws.async;


{ ************ TRestHttpServer RESTful Server }

type
  /// exception raised in case of a HTTP Server error
  ERestHttpServer = class(ERestException);

  /// available running options for TRestHttpServer.Create() constructor
  // - see HTTP_DEFAULT_MODE / WEBSOCKETS_DEFAULT_MODE for the best mode
  // - useHttpApi to run kernel-mode HTTP.SYS server (THttpApiServer) with an
  // already registered URI (default way, similar to IIS/WCF security policy
  // as specified by Microsoft) - you would need to register the URI by hand,
  // e.g. in the Setup program, via code similar to this one:
  // ! THttpApiServer.AddUrlAuthorize('root','888',false,'+'))
  // - useHttpApiRegisteringURI will first registry the given URI, then run
  // kernel-mode HTTP.SYS server (THttpApiServer) - will need Administrator
  // execution rights at least one time (e.g. during setup); note that if
  // the URI is already registered, the server will still be launched, even if
  // the program does not run as Administrator - it is therefore sufficient
  // to run such a program once as Administrator to register the URI, when this
  // useHttpApiRegisteringURI option is set
  // - useHttpApiOnly and useHttpApiRegisteringURIOnly won't fallback to the
  // socket-based HTTP server if http.sys initialization failed
  // - useHttpSocket will run the standard Sockets library (i.e. socket-based
  // THttpServer with one thread per kept alive connection), using a thread pool
  // for HTTP/1.0 requests (e.g. behind a reverse proxy) or one thread per
  // HTTP/1.1 keep alive connection, so won't scale without any reverse proxy
  // - useBidirSocket will use the standard Sockets library but via the
  // TWebSocketServerRest class, allowing HTTP connection upgrade to the
  // WebSockets protocol, to enable immediate event callbacks in addition to
  // the standard request/answer RESTful mode: will use one thread per client
  // so won't scale
  // - useHttpAsync will use the Sockets library in event-driven mode,
  // with a thread poll for HTTP/1.1 kept alive connections, so would scale
  // much better than older useHttpSocket - which is preferred for HTTP/1.0
  // - useBidirAsync will use TWebSocketAsyncServerRest in event-driven mode,
  // using its thread poll for all its HTTP or WebSockets process, , so would
  // scale much better than older useBidirSocket
  // - in practice, useHttpSocket is good behind a reverse proxy defined in
  // HTTP/1.0 mode, but useHttpAsync may scale much better in case of
  // a lot of concurrent connections, especially kept-alive connections
  // - useBidirSocket may be used for legacy reasons, if one thread per client
  // is a good idea - but useBidirAsync may be preferred for proper scaling
  // - on Windows, all sockets-based server will trigger the firewall popup UAC
  // window at first execution, unless your setup program did register the app
  TRestHttpServerUse = (
    {$ifdef USEHTTPSYS}
    useHttpApi,
    useHttpApiRegisteringURI,
    useHttpApiOnly,
    useHttpApiRegisteringURIOnly,
    {$endif USEHTTPSYS}
    useHttpSocket,
    useBidirSocket,
    useHttpAsync,
    useBidirAsync);

  /// available security options for TRestHttpServer.Create() constructor
  // - default secNone will use plain HTTP connection
  // - secTLS will use HTTPS secure connection
  // - secTLSSelfSigned will use HTTPS secure connection with a (temporary)
  // self-signed certificate - so clients should set IgnoreTlsCertificateErrors
  // - secSynShaAes will use a proprietary SHA-256 / AES-256-CTR encryption
  // identified as 'synshaaes' as ACCEPT-ENCODING: header parameter - but since
  // encodings are optional in HTTP, it is not possible to rely on it for securing
  // the line which may be plain, so this is marked as deprecated - use HTTPS or
  // encrypted WebSockets instead
  TRestHttpServerSecurity = (
    secNone,
    secTLS,
    secTLSSelfSigned
    {$ifndef PUREMORMOT2} ,
    secSynShaAes
    {$endif PUREMORMOT2}
    );


const
  /// the default access rights used by the HTTP server if none is specified
  HTTP_DEFAULT_ACCESS_RIGHTS: POrmAccessRights = @SUPERVISOR_ACCESS_RIGHTS;

  /// the TRestHttpServerSecurity flags which imply TLS/HTTPS
  SEC_TLS = [secTLS, secTLSSelfSigned];

  /// the kind of HTTP server to be used by default
  // - will define the best available server class, depending on the platform
  {$ifdef USEHTTPSYS}
  HTTP_DEFAULT_MODE = useHttpApiRegisteringURI;

  /// the kind of HTTP server which involves http.sys
  HTTP_API_MODES =
    [useHttpApi .. useHttpApiRegisteringURIOnly];

  /// the http.sys modes which won't have any fallback to the sockets server
  HTTP_API_REGISTERING_MODES =
    [useHttpApiRegisteringURI, useHttpApiRegisteringURIOnly];

  {$else}
  // - older useHttpSocket focuses on HTTP/1.0 or a small number of short-living
  // connections - creating one thread per HTTP/1.1 connection - so is a good
  // idea behind a nginx reverse proxy using HTTP/1.0, whereas our new
  // useHttpAsync server scales better with high number of HTTP/1.1 connections
  HTTP_DEFAULT_MODE = useHttpAsync;
  {$endif USEHTTPSYS}

  /// the kind of HTTP server to be used by default with/without TLS
  // - only our socket-based servers do allow setting certificates at runtime
  // - see also HTTPS_SECURITY[]
  HTTPS_DEFAULT_MODE: array[{tls=}boolean] of TRestHttpServerUse = (
    HTTP_DEFAULT_MODE,
    useHttpAsync);

  /// the kind of HTTP server to be used by default for WebSockets support
  // - will define the best available server class, depending on the platform
  // - useBidirSocket uses one thread per connection, whereas useBidirAsync
  // use a thread-pool and has an event-driven approach so scales much better
  WEBSOCKETS_DEFAULT_MODE = useBidirAsync;

  /// the kind of HTTP server which involves plain sockets, not http.sys
  HTTP_SOCKET_MODES = [
    useHttpSocket,
    useBidirSocket,
    useHttpAsync,
    useBidirAsync];

  /// the TRestHttpServerUse which have bi-directional callback notifications
  // - i.e. the THttpServerGeneric classes with CanNotifyCallback=true
  HTTP_BIDIR = [useBidirSocket, useBidirAsync];

  /// HTTP/HTTPS security flags for TRestHttpServer.Create() constructor
  // - see also HTTPS_DEFAULT_MODE[]
  HTTPS_SECURITY: array[{tls=}boolean] of TRestHttpServerSecurity = (
    secNone,
    secTLS);

  /// HTTP/HTTPS security flags for TRestHttpServer.Create() constructor
  // with an optional self-signed server certificate (if supported)
  // - see also HTTPS_DEFAULT_MODE[]
  HTTPS_SECURITY_SELFSIGNED: array[{selfsigned=}boolean, {tls=}boolean] of
      TRestHttpServerSecurity = (
    (secNone,
     secTLS),
    (secNone,
     secTLSSelfSigned));

type
  TRestHttpOneServer = record
    Server: TRestServer;
    RestAccessRights: POrmAccessRights;
    Security: TRestHttpServerSecurity;
  end;
  PRestHttpOneServer = ^TRestHttpOneServer;

  /// high-level callback able to customize any TRestHttpServer process
  // - as used by TRestHttpServer.OnCustomRequest property
  // - should return TRUE if the Call has been processed, false if the
  // registered TRestServer instances should handle this request
  // - please make this method thread-safe and as fast as possible
  TOnRestHttpServerRequest = function(var Call: TRestUriParams): boolean of object;

  /// HTTP/1.1 and WebSockets RESTFUL JSON mORMot Server class
  // - this HTTP/HTTPS server is multi-threaded and not blocking, shared between
  // one or several TRestServer instances, identified via their TOrmModel.Root
  // - depending on the constructor, one TRestHttpServerUse kind is used,
  // which may be over http.sys or blocking sockets, or asynchronous sockets,
  // able to upgrade to WebSockets or not - note that http.sys requires a
  // proper URI registration with administrator rights
  // - for a true AJAX server, see AccessControlAllowOrigin property and
  // consider TRestServer.NoAjaxJson := false for non-extended JSON transmission
  TRestHttpServer = class(TSynPersistent)
  protected
    fShutdownInProgress: boolean;
    fHttpServer: THttpServerGeneric;
    fPort, fDomainName: RawUtf8;
    fPublicAddress, fPublicPort: RawUtf8;
    fRestServers: array of TRestHttpOneServer;
    fRestServerNames: RawUtf8;
    fSingleRestServer: PRestHttpOneServer;
    fSafe: TRWLightLock; // protect fRestServers[]
    fHosts: TSynNameValue;
    fAccessControlAllowOrigin: RawUtf8;
    fAccessControlAllowOriginsMatch: TMatchs;
    fAccessControlAllowCredential: boolean;
    fUse: TRestHttpServerUse;
    fOptions: TRestHttpServerOptions;
    fRootRedirectToURI: array[boolean] of RawUtf8;
    fLog: TSynLogClass;
    fOnCustomRequest: TOnRestHttpServerRequest;
    procedure SetAccessControlAllowOrigin(const Value: RawUtf8);
    procedure ComputeAccessControlHeader(Ctxt: THttpServerRequestAbstract;
      ReplicateAllowHeaders: boolean);
    procedure ComputeHostUrl(Ctxt: THttpServerRequestAbstract; var HostUrl: RawUtf8);
    // assigned to fHttpServer.OnHttpThreadStart/Terminate e.g. to handle connections
    procedure HttpThreadStart(Sender: TThread); virtual;
    procedure HttpThreadTerminate(Sender: TThread); virtual;
    // implement the server response - must be thread-safe
    function Request(Ctxt: THttpServerRequestAbstract): cardinal; virtual;
    function GetRestServerCount: integer;
      {$ifdef HASINLINE}inline;{$endif}
    function GetRestServer(Index: integer): TRestServer;
      {$ifdef HASINLINE}inline;{$endif}
    procedure SetRestServerAccessRight(Index: integer; Value: POrmAccessRights);
    procedure SetRestServer(aIndex: integer; aServer: TRestServer;
      aSecurity: TRestHttpServerSecurity; aRestAccessRights: POrmAccessRights);
    function HttpApiAddUri(const aRoot, aDomainName: RawByteString;
      aSecurity: TRestHttpServerSecurity;
      aRegisterUri, aRaiseExceptionOnError: boolean): RawUtf8;
    function NotifyCallback(aSender: TRestServer;
      const aInterfaceDotMethodName, aParams: RawUtf8;
      aConnectionID: THttpServerConnectionID;
      aFakeCallID: integer; aResult, aErrorMsg: PRawUtf8): boolean;
    procedure OnWSClose(aConnectionID: TRestConnectionID;
      aConnectionOpaque: pointer);
    procedure OnWSSocketClose(Sender: TWebSocketServerSocket);
    procedure OnWSAsyncClose(Sender: TWebSocketAsyncConnection);
  public
    /// create a HTTP/HTTPS Server instance, to serve REST requests
    // - this is the easiest constructor to publish TRestServer(s) over HTTP/HTTPS
    // - will create a TWebSocketAsyncServerRest, i.e. our useBidirAsync server
    // which is available on all platforms, and supports TLS and WebSockets
    // - specify one or several TRestServer server class(es) to be used: each
    // class must have an unique Model.Root value, to identify which TRestServer
    // instance must handle a particular request from its URI
    // - port should specify the public server name or address to bind to: e.g.
    // 'domainname:1234', '0.0.0.0:1234' for all addresses, '127.0.0.1:1234' for
    // the TCP loopback, or 'unix:/path/to/myapp.socket' for the Unix domain
    // sockets loopback - raises a ERestHttpServer exception if binding failed
    // - the aThreadPoolCount parameter will set the number of threads
    // to be initialized to handle incoming connections (default is a good 32)
    // - for a HTTPS server, use secTLS and set CertificateFile, PrivateKeyFile,
    // and PrivateKeyPassword expected values, or specify secTLSSelfSigned
    // - see the overloaded constructors as alternatives with more options,
    // e.g. if you want to use http.sys on Windows or TLS mutual auth callbacks
    constructor Create(const aServers: array of TRestServer; const aPort: RawUtf8;
      aThreadPoolCount: integer = 32; aSecurity: TRestHttpServerSecurity = secNone;
      aOptions: TRestHttpServerOptions = HTTPSERVER_DEFAULT_OPTIONS;
      const CertificateFile: TFileName = ''; const PrivateKeyFile: TFileName = '';
      const PrivateKeyPassword: RawUtf8 = ''; const CACertificatesFile: TFileName = '');
        reintroduce; overload;
    /// create a Server instance, binded and listening on a TCP port to REST requests
    // - raise a ERestHttpServer exception if binding failed
    // - port is an RawUtf8/AnsiString, as expected by the WinSock API - in case
    // of useHttpSocket, useBidirSocket or useHttpAsync, useBidirAsync servers,
    // specify the public server address to bind to: e.g. '1.2.3.4:1234' - even
    // for http.sys, the public address could be used for TRestServer.SetPublicUri()
    // - aDomainName is the Urlprefix to be used for http.sys HttpAddUrl API call:
    // it could be either a fully qualified case-insensitive domain name
    // an IPv4 or IPv6 literal string, or a wildcard ('+' will bound
    // to all domain names for the specified port, '*' will accept the request
    // when no other listening hostnames match the request for that port) - this
    // parameter is ignored by the TRestHttpApiServer instance
    // - aUse defines how the HTTP server itself will be implemented: on Windows
    // by default the optimized kernel-based http.sys server (useHttpApi),
    // optionally registering the URI (useHttpApiRegisteringURI),
    // or using the standard Sockets library (useHttpSocket), possibly in its
    // WebSockets-friendly version (useBidirSocket - then call the
    // WebSocketsEnable method to initialize the available protocols), or
    // in its event-driven non-blocking versions (useHttpAsync/useBidirAsync)
    // - by default, the POrmAccessRights will be set to nil
    // - the aThreadPoolCount parameter will set the number of threads
    // to be initialized to handle incoming connections (default is 32, which
    // may be sufficient for most cases, maximum is 256)
    // - the aSecurity can be set to secTLS to initialize a HTTPS server (via
    // the TLS param for sockets, or after proper http.sys cert installation
    // as regularly done on Windows) or secTLSSelfSigned for a self-signed cert
    // - optional aAdditionalUrl parameter can be used e.g. to registry an URI
    // to server static file content, by overriding TRestHttpServer.Request
    // - for THttpApiServer, you can specify an optional name for the HTTP queue
    constructor Create(const aPort: RawUtf8;
      const aServers: array of TRestServer; const aDomainName: RawUtf8 = '+';
      aUse: TRestHttpServerUse = HTTP_DEFAULT_MODE;
      aThreadPoolCount: integer = 32;
      aSecurity: TRestHttpServerSecurity = secNone;
      const aAdditionalUrl: RawUtf8 = ''; const aQueueName: SynUnicode = '';
      aOptions: TRestHttpServerOptions = HTTPSERVER_DEFAULT_OPTIONS;
      TLS: PNetTlsContext = nil); reintroduce; overload;
    /// create a Server instance, binded and listening on a TCP port to HTTP requests
    // - overloaded function allowing to specify the expected POrmAccessRights
    // for the supplied TRestServer server instance
    constructor Create(const aPort: RawUtf8;
      aServer: TRestServer; const aDomainName: RawUtf8 = '+';
      aUse: TRestHttpServerUse = HTTP_DEFAULT_MODE;
      aRestAccessRights: POrmAccessRights = nil;
      aThreadPoolCount: integer = 32;
      aSecurity: TRestHttpServerSecurity = secNone;
      const aAdditionalUrl: RawUtf8 = ''; const aQueueName: SynUnicode = '';
      aOptions: TRestHttpServerOptions = HTTPSERVER_DEFAULT_OPTIONS);
        reintroduce; overload;
    /// create a Server instance, binded and listening on a TCP port to HTTP requests
    // - specify one TRestServer instance to be published, and the associated
    // transmission definition; other parameters would be the standard one
    // - only the supplied aDefinition.Authentication will be defined
    // - under Windows, will use http.sys with automatic URI registration, unless
    // aDefinition.WebSocketPassword is set and binary WebSockets would be
    // expected with the corresponding encryption, or aForcedKind is overriden
    // - optional aWebSocketsLoopDelay parameter could be set for tuning
    // WebSockets responsiveness
    constructor Create(aServer: TRestServer;
      aDefinition: TRestHttpServerDefinition;
      aForcedUse: TRestHttpServerUse = HTTP_DEFAULT_MODE;
      aWebSocketsLoopDelay: integer = 0); reintroduce; overload;
    /// release all memory, internal mORMot server and HTTP handlers
    destructor Destroy; override;
    /// you can call this method to prepare the HTTP server for shutting down
    // - it will call all associated TRestServer.Shutdown methods, unless
    // noRestServerShutdown is true
    // - note that Destroy won't call this method on its own, since the
    // TRestServer instances may have a life-time uncoupled from HTTP process
    procedure Shutdown(noRestServerShutdown: boolean = false);
    /// try to register another TRestServer instance to the HTTP server
    // - each TRestServer class must have an unique Model.Root value, to
    // identify which instance must handle a particular request from its URI
    // - an optional aRestAccessRights parameter is available to override the
    // default HTTP_DEFAULT_ACCESS_RIGHTS access right setting - but you shall
    // better rely on the authentication feature included in the framework
    // - the aHttpServerSecurity can be set to secTLS to initialize a HTTPS
    // instance (after proper certificate installation as explained in the SAD pdf)
    // - return true on success, false on error (e.g. duplicated Root value)
    function AddServer(aServer: TRestServer;
      aRestAccessRights: POrmAccessRights = nil;
      aSecurity: TRestHttpServerSecurity = secNone): boolean;
    /// un-register a TRestServer from the HTTP server
    // - each TRestServer class must have an unique Model.Root value, to
    // identify which instance must handle a particular request from its URI
    // - return true on success, false on error (e.g. specified server not found)
    function RemoveServer(aServer: TRestServer): boolean;
    /// register a domain name to be redirected to a given Model.Root
    // - i.e. can be used to support some kind of virtual hosting
    // - by default, the URI would be used to identify which TRestServer
    // instance to use, and the incoming HOST value would just be ignored
    // - you can specify here domain names which would be checked against
    // the incoming HOST header, to redirect to a given URI, as such:
    // ! DomainHostRedirect('project1.com','root1');
    // ! DomainHostRedirect('project2.com','root2');
    // ! DomainHostRedirect('blog.project2.com','root2/blog');
    // for the last entry, you may have for instance initialized a MVC web
    // server on the 'blog' sub-URI of the 'root2' TRestServer via:
    // !constructor TMyMvcApplication.Create(aRestModel: TRest; aInterface: PTypeInfo);
    // ! ...
    // ! fMainRunner := TMvcRunOnRestServer.Create(self,nil,'blog');
    // ! ...
    // - if aUri='' is given, the corresponding host redirection will be disabled
    // - note: by design, 'something.localhost' is likely to be not recognized
    // as aDomain, since 'localhost' can not be part of proper DNS resolution
    procedure DomainHostRedirect(const aDomain, aUri: RawUtf8);
    /// allow to temporarly redirect ip:port root URI to a given sub-URI
    // - by default, only sub-URI, as defined by TRestServer.Model.Root, are
    // registered - you can define here a sub-URI to reach when the main server
    // is directly accessed from a browser, e.g. localhost:port will redirect to
    // localhost:port/RedirectedUri
    // - for http.sys server, would try to register '/' if aRegisterUri is TRUE
    // - by default, will redirect http://localhost:port unless you set
    // aHttpServerSecurity=secTLS so that it would redirect https://localhost:port
    procedure RootRedirectToUri(const aRedirectedUri: RawUtf8;
      aRegisterUri: boolean = true; aHttps: boolean = false);
    /// specify URI routes for internal URI rewrites or callback execution
    // - just redirect to the HttpServer.Route function
    // - URI rewrites allow to extend the default routing, e.g. from TRestServer
    // - callbacks execution allow efficient server-side processing with parameters
    // - warning: with the THttpApiServer, URIs will be limited by the actual
    // root URI registered at http.sys level - there is no such limitation with
    // the socket servers, which bind to a port, so handle all URIs on it
    function Route: TUriRouter;
    /// defines the WebSockets protocols used by useBidirSocket/useBidirAsync
    // - i.e. 'synopsebinary' and optionally 'synopsejson' protocols
    // - if aWebSocketsURI is '', any URI would potentially upgrade; you can
    // specify an URI to limit the protocol upgrade to a single REST server
    // - TWebSocketProtocolBinary will always be registered by this method
    // - if the encryption key text is not '', TWebSocketProtocolBinary will
    // use AES-CFB 256 bits encryption
    // - if aWebSocketsAjax is TRUE, it will also register TWebSocketProtocolJson
    // so that AJAX applications would be able to connect to this server
    // - this method raise an EHttpServer if the associated server class does not
    // support WebSockets, i.e. this instance isn't useBidirSocket/useBidirAsync
    // - warning: only a single WebSockets server could be used in TRestServer
    // callback at the same time to avoid confusion between the WS connections
    function WebSocketsEnable(
      const aWSURI, aWSEncryptionKey: RawUtf8; aWSAjax: boolean = false;
      aWSBinaryOptions: TWebSocketProtocolBinaryOptions = [pboSynLzCompress];
      const aOnWSUpgraded: TOnWebSocketProtocolUpgraded = nil;
      const aOnWSClosed: TOnWebSocketProtocolClosed = nil): PWebSocketProcessSettings;
        overload;
    /// defines the WebSockets protocols used by useBidirSocket/useBidirAsync
    // - same as the overloaded WebSocketsEnable() method, but the URI will be
    // forced to match the aServer.Model.Root value, as expected on the client
    // side by TRestHttpClientWebsockets.WebSocketsUpgrade()
    function WebSocketsEnable(aServer: TRestServer;
      const aWSEncryptionKey: RawUtf8; aWSAjax: boolean = false;
      aWSBinaryOptions: TWebSocketProtocolBinaryOptions = [pboSynLzCompress];
      const aOnWSUpgraded: TOnWebSocketProtocolUpgraded = nil;
      const aOnWSClosed: TOnWebSocketProtocolClosed = nil): PWebSocketProcessSettings;
        overload;
    /// the TCP/IP (address and) port on which this server is listening to
    // - may contain the public server address to bind to: e.g. '1.2.3.4:1234'
    // - see PublicAddress and PublicPort properties if you want to get the
    // true IP port or address
    property Port: RawUtf8
      read fPort;
    /// the TCP/IP public address on which this server is listening to
    // - equals e.g. '1.2.3.4' if Port = '1.2.3.4:1234'
    // - if Port does not contain an explicit address (e.g. '1234'), the current
    // computer host name would be assigned as PublicAddress
    property PublicAddress: RawUtf8
      read fPublicAddress;
    /// the TCP/IP public port on which this server is listening to
    // - equals e.g. '1234' if Port = '1.2.3.4:1234'
    property PublicPort: RawUtf8
      read fPublicPort;
    /// the kind of HTTP Server used by this instance
    property Use: TRestHttpServerUse
      read fUse;
    /// read-only access to all internal servers
    property RestServer[Index: integer]: TRestServer
      read GetRestServer;
    /// write-only access to all internal servers access right
    // - can be used to override the default HTTP_DEFAULT_ACCESS_RIGHTS setting
    property RestServerAccessRight[Index: integer]: POrmAccessRights
      write SetRestServerAccessRight;
    /// find the first instance of a registered REST server
    // - note that the same REST server may appear several times in this HTTP
    // server instance, e.g. with diverse security options
    function RestServerFind(aServer: TRestServer): integer;
    /// low-level interception of all incoming requests
    // - this callback is called BEFORE any registered TRestServer.Uri() methods
    // so allow any kind of custom routing or process
    property OnCustomRequest: TOnRestHttpServerRequest
      read fOnCustomRequest write fOnCustomRequest;
    // backward compatibility methods and properties
    {$ifndef PUREMORMOT2}
    function DBServerFind(aServer: TRestServer): integer;
    property DBServerCount: integer
      read GetRestServerCount;
    property DBServer[Index: integer]: TRestServer
      read GetRestServer;
    property DBServerAccessRight[Index: integer]: POrmAccessRights
      write SetRestServerAccessRight;
    {$endif PUREMORMOT2}
  published
    /// the associated running HTTP server instance
    // - either THttpApiServer (available only under Windows), THttpServer,
    // TWebSocketServerRest or TWebSocketAsyncServerRest (on any system)
    property HttpServer: THttpServerGeneric
      read fHttpServer;
    /// the Urlprefix used for internal HttpAddUrl API call
    property DomainName: RawUtf8
      read fDomainName;
    /// read-only access to the number of registered internal servers
    property RestServerCount: integer
      read GetRestServerCount;
    /// allow to customize this TRestHttpServer process
    property Options: TRestHttpServerOptions
      read fOptions;
    /// enable cross-origin resource sharing (CORS) for proper AJAX process
    // - see @https://developer.mozilla.org/en-US/docs/HTTP/Access_control_CORS
    // - can be set e.g. to '*' to allow requests from any site/domain; or
    // specify an CSV white-list of URI to be allowed as origin e.g. as
    // 'https://foo.example1,https://foo.example2' or 'https://*.foo.example' or
    // (faster) '*.foo.example1,*.foo.example2' following the TMatch syntax
    // - see also AccessControlAllowCredential property
    property AccessControlAllowOrigin: RawUtf8
      read fAccessControlAllowOrigin write SetAccessControlAllowOrigin;
    /// enable cookies, authorization headers or TLS client certificates CORS exposition
    // - this option works with the AJAX XMLHttpRequest.withCredentials property
    // on client/JavaScript side, as stated by
    // @https://developer.mozilla.org/en-US/docs/Web/API/XMLHttpRequest/withCredentials
    // - see @https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Access-Control-Allow-Credentials
    property AccessControlAllowCredential: boolean
      read fAccessControlAllowCredential write fAccessControlAllowCredential;
  end;


function ToText(use: TRestHttpServerUse): PShortString; overload;
function ToText(sec: TRestHttpServerSecurity): PShortString; overload;


{ ************ TRestHttpRemoteLogServer to Receive Remote Log Stream }

type
  /// callback expected by TRestHttpRemoteLogServer to notify about a received log
  TRemoteLogReceivedOne = procedure(const Text: RawUtf8) of object;

  {$M+}
  /// limited HTTP server which is will receive remote log notifications
  // - this will create a simple in-memory mORMot server, which will trigger
  // a supplied callback when a remote log is received
  // - see TRestHttpClientWinGeneric.CreateForRemoteLogging() for the client side
  // - used e.g. by the LogView tool
  TRestHttpRemoteLogServer = class(TRestHttpServer)
  protected
    fServer: TRestServerFullMemory;
    fEvent: TRemoteLogReceivedOne;
  public
    /// initialize the HTTP server and an internal mORMot server
    // - you can share several HTTP log servers on the same port, if you use
    // a dedicated root URI and use the http.sys server (which is the default)
    constructor Create(const aRoot: RawUtf8; aPort: integer;
      const aEvent: TRemoteLogReceivedOne); reintroduce;
    /// release the HTTP server and its internal mORMot server
    destructor Destroy; override;
    /// the associated mORMot server instance running with this HTTP server
    property Server: TRestServerFullMemory
      read fServer;
  published
    /// this HTTP server will publish a 'RemoteLog' method-based service
    // - expecting PUT with text as body, at http://server/root/RemoteLog
    procedure RemoteLog(Ctxt: TRestServerUriContext);
  end;
  {$M-}


// backward compatibility types redirections
{$ifndef PUREMORMOT2}

  TSQLHTTPServerOptions = TRestHttpServerUse;
  TSQLHTTPServerSecurity = TRestHttpServerSecurity;
  TSQLHTTPServer = TRestHttpServer;
  TSQLHTTPRemoteLogServer = TRestHttpRemoteLogServer;

const
  secSSL = secTLS;

{$endif PUREMORMOT2}


implementation


{ ************ TRestHttpServer RESTful Server }

function ToText(use: TRestHttpServerUse): PShortString;
begin
  result := GetEnumName(TypeInfo(TRestHttpServerUse), ord(use));
end;

function ToText(sec: TRestHttpServerSecurity): PShortString;
begin
  result := GetEnumName(TypeInfo(TRestHttpServerSecurity), ord(sec));
end;


{ TRestHttpServer }

function TRestHttpServer.AddServer(aServer: TRestServer;
  aRestAccessRights: POrmAccessRights;
  aSecurity: TRestHttpServerSecurity): boolean;
var
  i, n: PtrInt;
  log: ISynLog;
begin
  result := false;
  if (self = nil) or
     (aServer = nil) or
     (aServer.Model = nil) then
    exit;
  log := fLog.Enter(self, 'AddServer');
  fSafe.WriteLock; // protect fRestServers[]
  try
    n := length(fRestServers);
    for i := 0 to n - 1 do
      if (fRestServers[i].Security = aSecurity) and
         (fRestServers[i].Server.Model.
           UriMatch(aServer.Model.Root, false) <> rmNoMatch) then
        exit; // register only once per URI Root address and per protocol
    {$ifdef USEHTTPSYS}
    if fUse in HTTP_API_MODES then
      if HttpApiAddUri(aServer.Model.Root, fDomainName, aSecurity,
          fUse in HTTP_API_REGISTERING_MODES, false) <> '' then
        exit;
    {$endif USEHTTPSYS}
    SetLength(fRestServers, n + 1);
    SetRestServer(n, aServer, aSecurity, aRestAccessRights);
    fRestServerNames := TrimU(fRestServerNames + ' ' + aServer.Model.Root);
    fHttpServer.ProcessName := fRestServerNames;
    result := true;
  finally
    fSafe.WriteUnLock;
    if log <> nil then
      log.Log(sllHttp, 'AddServer(%,Root=%,Port=%,Public=%:%)=% servers=%',
        [aServer, aServer.Model.Root, fPort, fPublicAddress, fPublicPort,
         BOOL_STR[result], fRestServerNames], self);
  end;
end;

function TRestHttpServer.RestServerFind(aServer: TRestServer): integer;
begin
  fSafe.ReadLock; // protect fRestServers[]
  try
    for result := 0 to Length(fRestServers) - 1 do
      if fRestServers[result].Server = aServer then
        exit;
    result := -1;
  finally
    fSafe.ReadUnLock;
  end;
end;

{$ifndef PUREMORMOT2}
function TRestHttpServer.DBServerFind(aServer: TRestServer): integer;
begin
  result := RestServerFind(aServer);
end;
{$endif PUREMORMOT2}

function TRestHttpServer.RemoveServer(aServer: TRestServer): boolean;
var
  i, j, n: PtrInt;
  log: ISynLog;
begin
  result := false;
  if (self = nil) or
     (aServer = nil) or
     (aServer.Model = nil) then
    exit;
  log := fLog.Enter(self, 'RemoveServer');
  fSafe.WriteLock; // protect fRestServers[]
  try
    n := high(fRestServers);
    for i := n downto 0 do // may appear several times, with another Security
      if fRestServers[i].Server = aServer then
      begin
        {$ifdef USEHTTPSYS}
        if fHttpServer.InheritsFrom(THttpApiServer) then
          if THttpApiServer(fHttpServer).RemoveUrl(aServer.Model.Root,
             fPublicPort, fRestServers[i].Security in SEC_TLS,
             fDomainName) <> NO_ERROR then
            log.Log(sllLastError, '%.RemoveUrl(%)',
              [self, aServer.Model.Root], self);
        {$endif USEHTTPSYS}
        for j := i to n - 1 do
          fRestServers[j] := fRestServers[j + 1];
        SetLength(fRestServers, n);
        dec(n);
        if n = 1 then
          fSingleRestServer := pointer(fRestServers)
        else
          fSingleRestServer := nil;
        aServer.OnNotifyCallback := nil;
        aServer.SetPublicUri('', '');
        result := true; // don't break here: may appear with another Security
      end;
  finally
    fSafe.WriteUnLock;
    if log <> nil then
      log.Log(sllHttp, '%.RemoveServer(Root=%)=%',
        [self, aServer.Model.Root, BOOL_STR[result]], self);
  end;
end;

procedure TRestHttpServer.DomainHostRedirect(const aDomain, aUri: RawUtf8);
var
  uri: TUri;
begin
  if uri.From(aDomain) and
     EndWith(uri.Server, '.LOCALHOST') then
    fLog.Add.Log(sllWarning, 'DomainHostRedirect(%) is very likely to be ' +
      'unresolved: consider using a real host name instead of the loopback',
      [aDomain], self);
  if aUri = '' then
    fHosts.Delete(aDomain)
  else
    // e.g. Add('project1.com','root1')
    fHosts.Add(aDomain, aUri);
end;

constructor TRestHttpServer.Create(const aServers: array of TRestServer;
  const aPort: RawUtf8; aThreadPoolCount: integer;
  aSecurity: TRestHttpServerSecurity; aOptions: TRestHttpServerOptions;
  const CertificateFile: TFileName; const PrivateKeyFile: TFileName;
  const PrivateKeyPassword: RawUtf8; const CACertificatesFile: TFileName);
var
  tls: TNetTlsContext;
begin
  InitNetTlsContext(tls, {server=}true,
    CertificateFile, PrivateKeyFile, PrivateKeyPassword, CACertificatesFile);
  Create(aPort, aServers, '+', useBidirAsync, aThreadPoolCount,
    aSecurity, '', '', aOptions, @tls);
end;

const
  HTTPSERVERSOCKETCLASS: array[useHttpSocket .. high(TRestHttpServerUse)] of
      THttpServerSocketGenericClass = (
    THttpServer,                 // useHttpSocket
    TWebSocketServerRest,        // useBidirSocket
    THttpAsyncServer,            // useHttpAsync
    TWebSocketAsyncServerRest);  // useBidirAsync

constructor TRestHttpServer.Create(const aPort: RawUtf8;
  const aServers: array of TRestServer; const aDomainName: RawUtf8;
  aUse: TRestHttpServerUse; aThreadPoolCount: integer;
  aSecurity: TRestHttpServerSecurity; const aAdditionalUrl: RawUtf8;
  const aQueueName: SynUnicode; aOptions: TRestHttpServerOptions;
  TLS: PNetTlsContext);
var
  i, j: PtrInt;
  hso: THttpServerOptions;
  ErrMsg: RawUtf8;
  log: ISynLog;
begin
  // prepare the running parameters
  if high(aServers) < 0 then
    fLog := TSynLog
  else
    fLog := aServers[0].LogClass;
  log := fLog.Enter('Create % (%) on port %',
    [ToText(aUse)^, ToText(aSecurity)^, aPort], self);
  fOptions := aOptions;
  inherited Create; // may have been overriden
  SetAccessControlAllowOrigin(''); // deny CORS by default
  fHosts.Init({casesensitive=}false);
  fDomainName := aDomainName;
  // aPort='publicip:port' or 'unix:/path/to/myapp.socket' or 'port'
  fPort := aPort;
  Split(RawUtf8(fPort), ':', fPublicAddress, fPublicPort);
  if fPublicAddress = 'unix' then
  begin
    // 'unix:/path/to/myapp.socket'
    fPublicPort := fPort; // to be recognized by TCrtSocket.Bind()
    fPublicAddress := '0.0.0.0';
  end
  else if fPublicPort = '' then
  begin
    // no publicip supplied -> bind to HostName
    fPublicPort := fPublicAddress;
    fPublicAddress := Executable.Host;
  end;
  fUse := aUse;
  // register the Server(s) URI(s)
  if high(aServers) >= 0 then
  begin
    for i := 0 to high(aServers) do
      if (aServers[i] = nil) or
         (aServers[i].Model = nil) then
        ErrMsg := 'Invalid TRestServer';
    if {%H-}ErrMsg = '' then
      for i := 0 to high(aServers) do
        with aServers[i].Model do
        begin
          fRestServerNames := fRestServerNames + ' ' + Root;
          for j := i + 1 to high(aServers) do
            if aServers[j].Model.UriMatch(Root, false) <> rmNoMatch then
              FormatUtf8('Duplicated Root URI: % and %',
                [Root, aServers[j].Model.Root], ErrMsg);
        end;
    if ErrMsg <> '' then
      ERestHttpServer.RaiseUtf8(
        '%.Create(% ): %', [self, fRestServerNames, ErrMsg]);
    TrimSelf(fRestServerNames);
    // associate before HTTP server is started, for TRestServer.BeginCurrentThread
    SetLength(fRestServers, length(aServers));
    for i := 0 to high(aServers) do
      SetRestServer(i, aServers[i], aSecurity, HTTP_DEFAULT_ACCESS_RIGHTS);
  end;
  // start the actual Server threads
  hso := [];
  if rsoHeadersUnFiltered in fOptions then
    include(hso, hsoHeadersUnfiltered);
  if rsoLogVerbose in fOptions then
    include(hso, hsoLogVerbose);
  if rsoIncludeDateHeader in fOptions then
    include(hso, hsoIncludeDateHeader);
  if rsoNoXPoweredHeader in fOptions then
    include(hso, hsoNoXPoweredHeader);
  if rsoBan40xIP in fOptions then
    include(hso, hsoBan40xIP);
  if rsoEnableLogging in fOptions then
    include(hso, hsoEnableLogging);
  if rsoTelemetryCsv in fOptions then
    include(hso, hsoTelemetryCsv);
  if rsoTelemetryJson in fOptions then
    include(hso, hsoTelemetryJson);
  if aSecurity in SEC_TLS then
    include(hso, hsoEnableTls);
  //include(hso, hsoHeadersInterning);
  if aThreadPoolCount < integer(SystemInfo.dwNumberOfProcessors) * 5 then
    include(hso, hsoThreadSmooting); // regular HW tends to like it
  {$ifdef USEHTTPSYS}
  if aUse in HTTP_API_MODES then
    if PosEx('Wine', OSVersionInfoEx) > 0 then
    begin
      if Assigned(log) then
        log.Log(sllWarning, '%: httpapi probably not well supported on % -> ' +
          'fallback to useHttpAsync', [ToText(aUse)^, OSVersionInfoEx], self);
      aUse := useHttpAsync; // the closest server we have using sockets
    end
    else
    try
      // first try to use fastest http.sys
      fHttpServer := THttpApiServer.Create(aQueueName, HttpThreadStart,
        HttpThreadTerminate, TrimU(fRestServerNames), hso);
      for i := 0 to high(aServers) do
        HttpApiAddUri(aServers[i].Model.Root, fDomainName, aSecurity,
          fUse in HTTP_API_REGISTERING_MODES, true);
      if aAdditionalUrl <> '' then
        HttpApiAddUri(aAdditionalUrl, fDomainName, aSecurity,
          fUse in HTTP_API_REGISTERING_MODES, true);
    except
      on E: Exception do
      begin
        if Assigned(log) then
          log.Log(sllError, '% for % % at%  -> fallback to socket-based server',
            [E, ToText(aUse)^, fHttpServer, fRestServerNames], self);
        FreeAndNilSafe(fHttpServer); // if http.sys initialization failed
        if fUse in [useHttpApiOnly, useHttpApiRegisteringURIOnly] then
          // propagate fatal exception with no fallback to the sockets server
          raise;
        aUse := useHttpSocket; // conservative: useHttpAsync less mature on Win
      end;
    end;
  {$endif USEHTTPSYS}
  if fHttpServer = nil then
  begin
    // create one instance of our pure socket servers
    // (on Windows, may be used as fallback if http.sys was unsuccessful)
    if aUse in [low(HTTPSERVERSOCKETCLASS)..high(HTTPSERVERSOCKETCLASS)] then
      fHttpServer := HTTPSERVERSOCKETCLASS[aUse].Create(fPort, HttpThreadStart,
        HttpThreadTerminate, TrimU(fRestServerNames), aThreadPoolCount, 30000, hso)
    else
      ERestHttpServer.RaiseUtf8('%.Create(% ): unsupported %',
        [self, fRestServerNames, ToText(aUse)^]);
    if aSecurity = secTLSSelfSigned then
      THttpServerSocketGeneric(fHttpServer).WaitStartedHttps({sec=}30)
    else
      THttpServerSocketGeneric(fHttpServer).WaitStarted({sec=}30, TLS);
  end;
  // setup the newly created HTTP server instance
  fHttpServer.OnRequest := Request; // main TRestServer(s) processing callback
  fHttpServer.SetFavIcon; // nice default icon for the browsers :)
  {$ifndef PUREMORMOT2} // deprecated since unsafe
  if aSecurity = secSynShaAes then
    fHttpServer.RegisterCompress(CompressShaAes, 0); // CompressMinSize=0
  {$endif PUREMORMOT2}
  if rsoCompressSynLZ in fOptions then // SynLZ registered first, as preferred
    fHttpServer.RegisterCompress(CompressSynLZ);
  if rsoCompressGZip in fOptions then
    fHttpServer.RegisterCompress(CompressGZip);
  {$ifdef USEHTTPSYS}
  if fHttpServer.InheritsFrom(THttpApiServer) then
    // allow fast multi-threaded requests
    if aThreadPoolCount > 1 then
      THttpApiServer(fHttpServer).Clone(aThreadPoolCount - 1);
  {$endif USEHTTPSYS}
  // last HTTP server handling callbacks would be set for the TRestServer(s)
  if fHttpServer.CanNotifyCallback then
    for i := 0 to high(fRestServers) do
      fRestServers[i].Server.OnNotifyCallback := NotifyCallback;
  // finish the TRestServer(s) startup
  for i := 0 to high(fRestServers) do
    fRestServers[i].Server.ComputeRoutes; // pre-compute URI routes
  if Assigned(log) then
    log.Log(sllHttp, '% initialized for %', [fHttpServer, fRestServerNames], self);
end;

constructor TRestHttpServer.Create(const aPort: RawUtf8; aServer: TRestServer;
  const aDomainName: RawUtf8; aUse: TRestHttpServerUse;
  aRestAccessRights: POrmAccessRights; aThreadPoolCount: integer;
  aSecurity: TRestHttpServerSecurity; const aAdditionalUrl: RawUtf8;
  const aQueueName: SynUnicode; aOptions: TRestHttpServerOptions);
begin
  Create(aPort, [aServer], aDomainName, aUse, aThreadPoolCount,
    aSecurity, aAdditionalUrl, aQueueName, aOptions);
  if aRestAccessRights <> nil then
    RestServerAccessRight[0] := aRestAccessRights;
end;

destructor TRestHttpServer.Destroy;
var
  log: ISynLog;
begin
  log := fLog.Enter(self, 'Destroy');
  if log <> nil then
    log.Log(sllHttp, '% finalized for %',
      [fHttpServer, Plural('server', length(fRestServers))], self);
  Shutdown(true); // but don't call fRestServers[i].Server.Shutdown
  FreeAndNilSafe(fHttpServer);
  inherited Destroy;
  fAccessControlAllowOriginsMatch.Free;
end;

procedure TRestHttpServer.Shutdown(noRestServerShutdown: boolean);
var
  i: PtrInt;
  {%H-}log: ISynLog;
begin
  if (self <> nil) and
     not fShutdownInProgress then
  begin
    log := fLog.Enter('Shutdown(%)', [BOOL_STR[noRestServerShutdown]], self);
    fShutdownInProgress := true;
    fHttpServer.Shutdown;
    fSafe.WriteLock; // protect fRestServers[]
    try
      for i := 0 to high(fRestServers) do
      begin
        if not noRestServerShutdown then
          fRestServers[i].Server.Shutdown;
        if TMethod(fRestServers[i].Server.OnNotifyCallback).Data = self then
          // avoid unexpected GPF, and proper TRestServer reuse
          fRestServers[i].Server.OnNotifyCallback := nil;
      end;
    finally
      fSafe.WriteUnLock;
    end;
  end;
end;

function TRestHttpServer.GetRestServer(Index: integer): TRestServer;
begin
  result := nil;
  if self = nil then
    exit;
  fSafe.ReadLock; // protect fRestServers[]
  try
    if cardinal(Index) < cardinal(length(fRestServers)) then
      result := fRestServers[Index].Server;
  finally
    fSafe.ReadUnLock;
  end;
end;

function TRestHttpServer.GetRestServerCount: integer;
begin
  result := length(fRestServers);
end;

procedure TRestHttpServer.SetRestServerAccessRight(Index: integer;
  Value: POrmAccessRights);
begin
  if self = nil then
    exit;
  fSafe.WriteLock; // protect fRestServers[]
  try
    if Value = nil then
      Value := HTTP_DEFAULT_ACCESS_RIGHTS;
    if cardinal(Index) < cardinal(length(fRestServers)) then
      fRestServers[Index].RestAccessRights := Value;
  finally
    fSafe.WriteUnLock;
  end;
end;

procedure TRestHttpServer.SetRestServer(aIndex: integer; aServer: TRestServer;
  aSecurity: TRestHttpServerSecurity; aRestAccessRights: POrmAccessRights);
begin
  // note: caller should have made fSafe.WriteLock
  if self = nil then
    exit;
  if cardinal(aIndex) < cardinal(length(fRestServers)) then
    with fRestServers[aIndex] do
    begin
      Server := aServer;
      if (fHttpServer <> nil) and
         fHttpServer.CanNotifyCallback then
        Server.OnNotifyCallback := NotifyCallback;
      Server.SetPublicUri(fPublicAddress, fPublicPort);
      Security := aSecurity;
      if aRestAccessRights = nil then
        RestAccessRights := HTTP_DEFAULT_ACCESS_RIGHTS
      else
        RestAccessRights := aRestAccessRights;
    end;
  if length(fRestServers) = 1 then
    fSingleRestServer := pointer(fRestServers)
  else
    fSingleRestServer := nil;
end;

const
  HTTPS_TEXT: array[boolean] of string[1] = (
    '', 's');

procedure TRestHttpServer.RootRedirectToUri(const aRedirectedUri: RawUtf8;
  aRegisterUri: boolean; aHttps: boolean);
begin
  if fRootRedirectToUri[aHttps] = aRedirectedUri then
    exit;
  fLog.Add.Log(sllHttp, 'Redirect http%://localhost:% to http%://localhost:%/%',
    [HTTPS_TEXT[aHttps], fPublicPort, HTTPS_TEXT[aHttps], fPublicPort,
     aRedirectedUri], self);
  fRootRedirectToUri[aHttps] := aRedirectedUri;
  if aRedirectedUri <> '' then
    HttpApiAddUri('/', '+', HTTPS_SECURITY[aHttps], aRegisterUri, true);
end;

function TRestHttpServer.Route: TUriRouter;
begin
  if (self = nil) or
     (fHttpServer = nil) then
    result := nil
  else
    result := fHttpServer.Route;
end;

function TRestHttpServer.HttpApiAddUri(const aRoot, aDomainName: RawByteString;
  aSecurity: TRestHttpServerSecurity;
  aRegisterUri, aRaiseExceptionOnError: boolean): RawUtf8;
{$ifdef USEHTTPSYS}
var
  err: integer;
  https: boolean;
begin
  result := '';
  if not fHttpServer.InheritsFrom(THttpApiServer) then
    exit;
  https := aSecurity in SEC_TLS;
  fLog.Add.Log(sllHttp, 'http.sys registration of http%://%:%/%',
    [HTTPS_TEXT[https], aDomainName, fPublicPort, aRoot], self);
  // try to register the URL to http.sys
  err := THttpApiServer(fHttpServer).AddUrl(aRoot, fPublicPort, https,
    aDomainName, aRegisterUri);
  if err = NO_ERROR then
    exit;
  FormatUtf8('http.sys URI registration error #% for http%://%:%/%',
    [err, HTTPS_TEXT[https], aDomainName, fPublicPort, aRoot], result);
  if err = ERROR_ACCESS_DENIED then
    if aRegisterUri then
      result := result +
        ' (administrator rights needed, at least once to register the URI)'
    else
      result := result +
        ' (you need to register the URI - try to use useHttpApiRegisteringURI)';
  fLog.Add.Log(sllLastError, result, self);
  if aRaiseExceptionOnError then
    ERestHttpServer.RaiseUtf8('%: %', [self, result]);
end;
{$else}
begin
  result := ''; // do nothing, but no error
end;
{$endif USEHTTPSYS}

procedure AdjustHostUrl(
  var Call: TRestUriParams; Server: TRestServer; const HostRoot: RawUtf8);
var
  loc: RawUtf8;
  hostlen: PtrInt;
begin
  // caller ensured HostRoot <> ''
  if (Call.OutStatus = HTTP_MOVEDPERMANENTLY) or
     (Call.OutStatus = HTTP_TEMPORARYREDIRECT) then
  begin
    loc := FindIniNameValue(pointer(Call.OutHead), 'LOCATION: ');
    if (loc <> '') and
       (loc[1] = '/') then
      delete(loc, 1, 1); // what is needed for real URI doesn't help here
    hostlen := length(HostRoot);
    if (length(loc) > hostlen) and
       (loc[hostlen + 1] = '/') and
       IdemPropNameU(HostRoot, pointer(loc), hostlen) then
      // hostroot/method -> method on same domain
      Call.OutHead := 'Location: ' + copy(loc, hostlen + 1, maxInt);
  end
  else if (Server <> nil) and
          ExistsIniName(pointer(Call.OutHead), 'SET-COOKIE:') then
    // cookie Path=/hostroot... -> /...
    Call.OutHead := StringReplaceAll(Call.OutHead,
      '; Path=/' + Server.Model.Root, '; Path=/')
end;

function TRestHttpServer.Request(Ctxt: THttpServerRequestAbstract): cardinal;
var
  call: TRestUriParams;
  tls, matchcase: boolean;
  match: TRestModelMatch;
  i: PtrInt;
  P: PUtf8Char;
  serv: TRestServer;
begin
  // validate non-REST kind of requests
  if (self = nil) or
     (pointer(fRestServers) = nil) or
     fShutdownInProgress then
  begin
    result := HTTP_NOTFOUND;
    exit;
  end;
  tls := hsrHttps in Ctxt.ConnectionFlags;
  if IsGet(Ctxt.Method) then
    if (Ctxt.Url = '') or
       (PWord(Ctxt.Url)^ = ord('/')) then
      // RootRedirectToUri() to redirect ip:port root URI to a given sub-URI
      if fRootRedirectToUri[tls] <> '' then
      begin
        Ctxt.AddOutHeader(['Location: ', fRootRedirectToUri[tls]]);
        result := HTTP_TEMPORARYREDIRECT;
        exit;
      end
      else
      begin
        result := HTTP_BADREQUEST; // we need an URI to identify the REST server
        exit;
      end;
  if (Ctxt.Method = '') or
     ((rsoOnlyJsonRequests in fOptions) and
      not IsGet(Ctxt.Method) and
      not IdemPChar(pointer(Ctxt.InContentType), JSON_CONTENT_TYPE_UPPER)) then
  begin
    // wrong Input parameters or not JSON request: 400 BAD REQUEST
    result := HTTP_BADREQUEST;
    exit;
  end;
  if IsOptions(Ctxt.Method) then
  begin
    // handle CORS
    if fAccessControlAllowOrigin = '' then
      Ctxt.OutCustomHeaders := 'Access-Control-Allow-Origin:'
    else
      ComputeAccessControlHeader(Ctxt, {ReplicateAllowHeaders=}true);
    result := HTTP_NOCONTENT;
    exit;
  end;
  if (Ctxt.InContent <> '') and
     (rsoOnlyValidUtf8 in fOptions) and
     (IdemPChar(pointer(Ctxt.InContentType), JSON_CONTENT_TYPE_UPPER) or
      IdemPChar(pointer(Ctxt.InContentType), 'TEXT/')) and
     not IsValidUtf8(Ctxt.InContent) then // may use AVX2
  begin
    // rsoOnlyValidUtf8 rejection
    result := HTTP_NOTACCEPTABLE;
    exit;
  end;
  // compute the REST-oriented request information
  call.OutStatus := 0; // see call.Init
  call.OutInternalState := 0;
  call.RestAccessRights := nil;
  call.LowLevelConnectionID := Ctxt.ConnectionID;
  call.LowLevelConnectionOpaque := pointer(Ctxt.ConnectionOpaque);
  call.LowLevelConnectionFlags := TRestUriParamsLowLevelFlags(Ctxt.ConnectionFlags);
  call.LowLevelRemoteIP := Ctxt.RemoteIP;
  call.LowLevelBearerToken := Ctxt.AuthBearer;
  call.LowLevelUserAgent := Ctxt.UserAgent;
  if fHosts.Count > 0 then
    // handle any virtual host domain
    ComputeHostUrl(Ctxt, call.Url)
  else
    // no AdjustHostUrl() below
    Ctxt.Host := '';
  if call.Url = '' then
  begin
    call.Url := Ctxt.Url;
    if (call.Url <> '') and
       (call.Url[1] = '/') then
      delete(call.Url, 1, 1); // normalize URI
  end;
  call.Method := Ctxt.Method;
  call.InHead := Ctxt.InHeaders;
  call.InBody := Ctxt.InContent;
  // allow custom URI routing before TRestServer instances
  serv := nil;
  if (not Assigned(fOnCustomRequest)) or
     (not fOnCustomRequest(call)) then
  begin
    // search and call any matching TRestServer instance
    result := HTTP_NOTFOUND; // page not found by default (e.g. wrong URL)
    match := rmNoMatch;
    matchcase := rsoRedirectServerRootUriForExactCase in fOptions;
    if fSingleRestServer <> nil then
      // optimized for the most common case of a single DB server
      with fSingleRestServer^ do
      begin
        if (Security in SEC_TLS) = tls then
        begin
          match := Server.Model.UriMatch(call.Url, matchcase);
          if match = rmNoMatch then
            if rsoAllowSingleServerNoRoot in fOptions then
            begin
              match := rmMatchExact; // forge proper 'modelroot/url'
              call.Url := Server.Model.Root + '/' + call.Url;
            end
            else
              exit;
          call.RestAccessRights := RestAccessRights;
          serv := Server;
        end;
      end
    else
    begin
      // thread-safe use of dynamic fRestServers[] array
      fSafe.ReadLock;
      try
        for i := 0 to length(fRestServers) - 1 do
          with fRestServers[i] do
            if (Security in SEC_TLS) = tls then
            begin
              // registered for http or https
              match := Server.Model.UriMatch(call.Url, matchcase);
              if match = rmNoMatch then
                continue;
              call.RestAccessRights := RestAccessRights;
              serv := Server;
              break;
            end;
      finally
        fSafe.ReadUnLock;
      end;
    end;
    if (match = rmNoMatch) or
       (serv = nil) then
      exit;
    if matchcase and
       (match = rmMatchWithCaseChange) then
    begin
      // force redirection to exact Server.Model.Root case sensitivity
      call.OutStatus := HTTP_TEMPORARYREDIRECT;
      call.OutHead := 'Location: /' + call.Url;
      MoveFast(pointer(serv.Model.Root)^, PByteArray(call.OutHead)[11],
        length(serv.Model.Root)); // overwrite url root from Model.Root
    end
    else
      // call matching TRestServer.Uri()
      serv.Uri(call);
  end;
  // set output content
  result := call.OutStatus;
  Ctxt.OutContent := call.OutBody;
  P := pointer(call.OutHead);
  if IdemPChar(P, 'CONTENT-TYPE: ') then
  begin
    // TRestServer.Uri is expected to customize the content-type
    // as FIRST header (e.g. when returning GET blob fields)
    Ctxt.OutContentType := GetNextLine(P + 14, P);
    FastSetString(call.OutHead, P, StrLen(P));
  end
  else
    // default content type is JSON
    Ctxt.OutContentType := JSON_CONTENT_TYPE_VAR;
  // handle HTTP redirection and cookies over virtual hosts
  if Ctxt.Host <> '' then
    AdjustHostUrl(call, serv, Ctxt.Host);
  TrimSelf(call.OutHead);
  Ctxt.OutCustomHeaders := call.OutHead;
  if call.OutInternalState <> 0 then
    Ctxt.AddOutHeader(['Server-InternalState: ', call.OutInternalState]);
  // handle optional CORS origin
  if fAccessControlAllowOrigin <> '' then
    ComputeAccessControlHeader(Ctxt, {ReplicateAllowHeaders=}false);
end;

procedure TRestHttpServer.HttpThreadTerminate(Sender: TThread);
var
  i: PtrInt;
begin
  if self = nil then
    exit;
  fSafe.WriteLock; // protect fRestServers[]
  try
    for i := 0 to high(fRestServers) do
      fRestServers[i].Server.Run.EndCurrentThread(Sender);
  finally
    fSafe.WriteUnLock;
  end;
end;

procedure TRestHttpServer.HttpThreadStart(Sender: TThread);
var
  i: PtrInt;
begin
  if self = nil then
    exit;
  if CurrentThreadNameShort^ = '' then
    SetCurrentThreadName('% %% %', [self, fPort, fRestServerNames, Sender]);
  fSafe.WriteLock; // protect fRestServers[]
  try
    for i := 0 to high(fRestServers) do
      fRestServers[i].Server.Run.BeginCurrentThread(Sender);
  finally
    fSafe.WriteUnLock;
  end;
end;

procedure TRestHttpServer.SetAccessControlAllowOrigin(const Value: RawUtf8);
var
  patterns: TRawUtf8DynArray;
begin
  fAccessControlAllowOrigin := Value;
  FreeAndNil(fAccessControlAllowOriginsMatch);
  if (Value = '') or
     (Value = '*') then
    exit;
  CsvToRawUtf8DynArray(pointer(Value), patterns);
  if patterns = nil then
    exit;
  fAccessControlAllowOriginsMatch :=
    TMatchs.Create(patterns, {caseinsensitive=}true);
end;

procedure TRestHttpServer.ComputeAccessControlHeader(
  Ctxt: THttpServerRequestAbstract; ReplicateAllowHeaders: boolean);
var
  headers, origin: RawUtf8;
begin
  if ReplicateAllowHeaders then
  begin
    FindNameValue(Ctxt.InHeaders, 'ACCESS-CONTROL-REQUEST-HEADERS:', headers);
    Ctxt.AddOutHeader(['Access-Control-Allow-Headers: ', headers]);
  end;
  // note: caller did ensure that fAccessControlAllowOrigin<>''
  FindNameValue(Ctxt.InHeaders, 'ORIGIN: ', origin);
  if origin = '' then
    exit;
  if fAccessControlAllowOrigin = '*' then
    origin := fAccessControlAllowOrigin
  else if fAccessControlAllowOriginsMatch.Match(origin) < 0 then
    exit;
  Ctxt.AddOutHeader([
    'Access-Control-Allow-Methods: POST, PUT, GET, DELETE, LOCK, OPTIONS'#13#10 +
    'Access-Control-Max-Age: 1728000'#13#10 +
    // see http://blog.import.io/tech-blog/exposing-headers-over-cors-with-access-control-expose-headers
    'Access-Control-Expose-Headers: content-length,location,server-internalstate'#13#10 +
    'Access-Control-Allow-Origin: ', origin]);
  if fAccessControlAllowCredential then
    Ctxt.AddOutHeader(['Access-Control-Allow-Credentials: true']);
end;

procedure TRestHttpServer.ComputeHostUrl(
  Ctxt: THttpServerRequestAbstract; var HostUrl: RawUtf8);
begin
  // caller ensured fHosts.Count > 0
  HostUrl := GetFirstCsvItem(Ctxt.Host, ':'); // trim any port
  if HostUrl <> '' then
    // e.g. 'Host: project1.com' -> 'root1'
    HostUrl := fHosts.Value(HostUrl);
  if HostUrl <> '' then
    // e.g. 'Host: project1.com' -> 'root1/url'
    if (Ctxt.Url <> '') and
       (PWord(Ctxt.Url)^ <> ord('/')) then
      if Ctxt.Url[1] = '/' then
        HostUrl := HostUrl + Ctxt.Url
      else
        HostUrl := HostUrl + '/' + Ctxt.Url;
end;

function TRestHttpServer.WebSocketsEnable(const aWSURI, aWSEncryptionKey: RawUtf8;
  aWSAjax: boolean; aWSBinaryOptions: TWebSocketProtocolBinaryOptions;
  const aOnWSUpgraded: TOnWebSocketProtocolUpgraded;
  const aOnWSClosed: TOnWebSocketProtocolClosed): PWebSocketProcessSettings;
begin
  if not (fUse in HTTP_BIDIR) then
    EHttpServer.RaiseUtf8(
      'Unexpected %.WebSocketsEnable over % - need e.g. WEBSOCKETS_DEFAULT_MODE',
      [self, ToText(fUse)^]);
  result := (fHttpServer as THttpServerSocketGeneric).WebSocketsEnable(
    aWSURI, aWSEncryptionKey, aWSAjax, aWSBinaryOptions);
  if Assigned(aOnWSUpgraded) or
     Assigned(aOnWSClosed) then
    if fHttpServer is TWebSocketAsyncServer then
    begin
      TWebSocketAsyncServer(fHttpServer).OnWebSocketUpgraded := aOnWSUpgraded;
      TWebSocketAsyncServer(fHttpServer).OnWebSocketClose := aOnWSClosed;
      TWebSocketAsyncServer(fHttpServer).OnWebSocketDisconnect := OnWSAsyncClose;
    end
    else if fHttpServer is TWebSocketServer then
    begin
      TWebSocketServer(fHttpServer).OnWebSocketUpgraded := aOnWSUpgraded;
      TWebSocketServer(fHttpServer).OnWebSocketClose := aOnWSClosed;
      TWebSocketServer(fHttpServer).OnWebSocketDisconnect := OnWSSocketClose;
    end;
end;

function TRestHttpServer.WebSocketsEnable(aServer: TRestServer;
  const aWSEncryptionKey: RawUtf8; aWSAjax: boolean;
  aWSBinaryOptions: TWebSocketProtocolBinaryOptions;
  const aOnWSUpgraded: TOnWebSocketProtocolUpgraded;
  const aOnWSClosed: TOnWebSocketProtocolClosed): PWebSocketProcessSettings;
begin
  if (aServer = nil) or
     (RestServerFind(aServer) < 0) then
    EWebSockets.RaiseUtf8('%.WebSocketEnable(aServer=%?)', [self, aServer]);
  result := WebSocketsEnable(aServer.Model.Root, aWSEncryptionKey,
    aWSAjax, aWSBinaryOptions, aOnWSUpgraded, aOnWSClosed);
end;

function TRestHttpServer.NotifyCallback(aSender: TRestServer;
  const aInterfaceDotMethodName, aParams: RawUtf8;
  aConnectionID: THttpServerConnectionID; aFakeCallID: integer;
  aResult, aErrorMsg: PRawUtf8): boolean;
var
  ctxt: THttpServerRequest;
  url: RawUtf8;
  status: cardinal;
begin
  result := false;
  if (self <> nil) and
     not fShutdownInProgress then
  try
    if fHttpServer <> nil then
    begin
      // aConnection.InheritsFrom(TSynThread) may raise an exception
      // -> checked in WebSocketsCallback/IsActiveWebSocket
      ctxt := THttpServerRequest.Create(nil, aConnectionID, nil, [], nil);
      try
        FormatUtf8('%/%/%',
          [aSender.Model.Root, aInterfaceDotMethodName, aFakeCallID], url);
        ctxt.PrepareDirect(url, 'POST', '', '[' + aParams + ']', '', '');
        // fHttpServer.Callback() raises EHttpServer but for bidir servers
        status := fHttpServer.Callback(ctxt, {nonblocking=}aResult = nil);
        if status = HTTP_SUCCESS then
        begin
          if aResult <> nil then
            if IdemPChar(pointer(ctxt.OutContent), '{"RESULT":') then
              aResult^ := copy(ctxt.OutContent, 11, maxInt)
            else
              aResult^ := ctxt.OutContent;
          result := true;
        end
        else if aErrorMsg <> nil then
          FormatUtf8('%.Callback(%) returned status=% for %',
            [fHttpServer, aConnectionID, status, ctxt.Url], aErrorMsg^);
      finally
        ctxt.Free;
      end;
    end
    else if aErrorMsg <> nil then
      FormatUtf8('%.NotifyCallback with fHttpServer=nil', [self], aErrorMsg^);
  except
    on E: Exception do
      if aErrorMsg <> nil then
        ObjectToJson(E, aErrorMsg^, TEXTWRITEROPTIONS_DEBUG);
  end;
end;

procedure TRestHttpServer.OnWSClose(aConnectionID: TRestConnectionID;
  aConnectionOpaque: pointer);
var
  i: PtrInt;
  services: TServiceContainer;
begin
  if aConnectionID = 0 then
    exit;
  // we need to notify all REST servers, since a single connection could
  // in practice redirect to any of them
  fSafe.ReadLock; // protect fRestServers[]
  try
    for i := 0 to length(fRestServers) - 1 do
    begin
      services := fRestServers[i].Server.Services;
      if services <> nil then
        (services as TServiceContainerServer).
          RemoveFakeCallbackOnConnectionClose(aConnectionID, aConnectionOpaque);
    end;
  finally
    fSafe.ReadLock;
  end;
end;

procedure TRestHttpServer.OnWSSocketClose(Sender: TWebSocketServerSocket);
begin
  OnWSClose(Sender.RemoteConnectionID, Sender.GetConnectionOpaque);
end;

procedure TRestHttpServer.OnWSAsyncClose(Sender: TWebSocketAsyncConnection);
begin
  OnWSClose(Sender.Handle, Sender.GetConnectionOpaque);
end;

constructor TRestHttpServer.Create(aServer: TRestServer;
  aDefinition: TRestHttpServerDefinition; aForcedUse: TRestHttpServerUse;
  aWebSocketsLoopDelay: integer);
const
  AUTH: array[TRestHttpServerRestAuthentication] of
    TRestServerAuthenticationClass = (
    // adDefault, adHttpBasic, adWeak, adSspi
    TRestServerAuthenticationDefault,
    TRestServerAuthenticationHttpBasic,
    TRestServerAuthenticationNone,
    {$ifdef DOMAINRESTAUTH}
    // use mormot.lib.sspi/gssapi units depending on the OS
    TRestServerAuthenticationSspi
    {$else}
    nil
    {$endif DOMAINRESTAUTH});
var
  a: TRestHttpServerRestAuthentication;
  P: PUtf8Char;
  hostroot, host, root: RawUtf8;
  thrdcnt: integer;
begin
  if aDefinition = nil then
    ERestHttpServer.RaiseUtf8('%.Create(aDefinition=nil)', [self]);
  if aDefinition.WebSocketPassword <> '' then
    aForcedUse := WEBSOCKETS_DEFAULT_MODE; //= useBidirAsync
  if aDefinition.ThreadCount = 0 then
    thrdcnt := 32
  else
    thrdcnt := aDefinition.ThreadCount;
  Create(aDefinition.BindPort, aServer, '+', aForcedUse, nil, thrdcnt,
    HTTPS_SECURITY[aDefinition.Https], '', aDefinition.HttpSysQueueName,
    aDefinition.Options);
  if aDefinition.EnableCors <> '' then
  begin
    AccessControlAllowOrigin := aDefinition.EnableCors;
    AccessControlAllowCredential := true;
  end;
  if aDefinition.RootRedirectToUri <> '' then
    RootRedirectToUri(
      aDefinition.RootRedirectToUri, {reguri=}false, {https=}aDefinition.Https);
  P := pointer(aDefinition.DomainHostRedirect);
  while P <> nil do
  begin
    GetNextItem(P, ',', hostroot);
    Split(hostroot, '=', host, root);
    if (host <> '') and
       (root <> '') then
      DomainHostRedirect(host, root);
  end;
  if fHttpServer <> nil then
  begin
    fHttpServer.RemoteIPHeader := aDefinition.RemoteIPHeader;
    if fHttpServer.InheritsFrom(THttpServerSocketGeneric) then
    begin
      if aDefinition.NginxSendFileFrom <> '' then
        THttpServerSocketGeneric(fHttpServer).NginxSendFileFrom(
          aDefinition.NginxSendFileFrom);
    end;
  end;
  a := aDefinition.Authentication;
  if aServer.HandleAuthentication then
    if AUTH[a] = nil then
      fLog.Add.Log(sllWarning, 'Create: Ignored unsupported',
        TypeInfo(TRestHttpServerRestAuthentication), a, self)
    else
    begin
      aServer.AuthenticationUnregisterAll;
      aServer.AuthenticationRegister(AUTH[a]);
    end;
  if aDefinition.WebSocketPassword <> '' then
    WebSocketsEnable(aServer, aDefinition.PasswordPlain)^.
      LoopDelay := aWebSocketsLoopDelay;
end;



{ ************ TRestHttpRemoteLogServer to Receive Remote Log Stream }

{ TRestHttpRemoteLogServer }

constructor TRestHttpRemoteLogServer.Create(const aRoot: RawUtf8;
  aPort: integer; const aEvent: TRemoteLogReceivedOne);
var
  aModel: TOrmModel;
begin
  aModel := TOrmModel.Create([], aRoot);
  fServer := TRestServerFullMemory.Create(aModel);
  aModel.Owner := fServer;
  fServer.ServiceMethodRegisterPublishedMethods('', self);
  fServer.AcquireExecutionMode[execSoaByMethod] := amLocked; // protect aEvent
  inherited Create(UInt32ToUtf8(aPort), fServer, '+', HTTP_DEFAULT_MODE, nil, 1);
  fEvent := aEvent;
  SetAccessControlAllowOrigin('*'); // e.g. when called from AJAX/SMS
end;

destructor TRestHttpRemoteLogServer.Destroy;
begin
  try
    inherited Destroy;
  finally
    fServer.Free;
  end;
end;

procedure TRestHttpRemoteLogServer.RemoteLog(Ctxt: TRestServerUriContext);
begin
  if Assigned(fEvent) and
     (Ctxt.Method = mPUT) then
  begin
    fEvent(Ctxt.Call^.InBody);
    Ctxt.Success;
  end;
end;



end.

