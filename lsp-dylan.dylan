Module: lsp-dylan
Synopsis: Test stuff for language server protocol
Author: Peter
Copyright: 2019


define constant $log
  = make(<log>,
         name: "lsp-dylan",
         targets: list($stderr-log-target),
         // For now just displaying millis is a good way to identify all the
         // messages that belong to a given call/response, and it's terse.
         formatter: "%{millis} %{level} [%{thread}] - %{message}");

define function local-log(m :: <string>, #rest params) => ()
  apply(log-debug, $log, m, params);
end function;


define constant $message-type-error = 1;
define constant $message-type-warning = 2;
define constant $message-type-info = 3;
define constant $message-type-log = 4;

define method window/show-message
    (session :: <session>, msg-type :: <integer>, msg :: <string>) => ()
  let params = json("type", msg-type, "message", msg);
  send-notification(session, "window/showMessage", params);
end method;

define method show-error
    (session :: <session>, msg :: <string>) => ()
  window/show-message(session, $message-type-error, msg);
end method;

define inline method show-warning
    (session :: <session>, msg :: <string>) => ()
  window/show-message(session, $message-type-warning, msg);
end method;

define inline method show-info
    (session :: <session>, msg :: <string>) => ()
  window/show-message(session, $message-type-info, msg);
end method;

define inline method show-log
    (session :: <session>, msg :: <string>) => ()
  window/show-message(session, $message-type-log, msg);
end method;

define function make-range(start, endp)
  json("start", start, "end", endp);
end function;

/*
 * Make a Position object
 * See https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#position
 */
define function make-position(line, character)
  json("line", line, "character", character);
end function;

/*
 * Make a Location that's 'zero size' range
 * See https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#location
 */
define function make-location(doc, line, character)
  let pos = make-position(line, character);
  json("uri", doc, "range", make-range(pos, pos))
end;

/*
 * Decode a Position object.
 * Note line and character are zero-based.
 * See https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#position
 */
define function decode-position(position)
 => (line :: <integer>, character :: <integer>)
  let line = as(<integer>, position["line"]);
  let character = as(<integer>, position["character"]);
  values(line, character)
end function;

/*
 * Create a MarkupContent object.
 * See https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#markupContent
 */
define function make-markup(txt, #key markdown = #f)
  let kind = if (markdown)
               "markdown"
             else
               "plaintext"
             end;
  json("value", txt,
       "kind", kind);
end function;

define function handle-workspace/symbol (session :: <session>,
                                         id :: <object>,
                                         params :: <object>)
  => ()
  // TODO this is only a dummy
  let query = params["query"];
  local-log("Query: %s", query);
  let range = make-range(make-position(0, 0), make-position(0,5));
  let symbols = list(json("name", "a-name",
                          "kind", 13,
                          "location", json("range", range,
                                           "uri", "file:///home/peter/Projects/lsp-dylan/lsp-dylan.dylan")));
  send-response(session, id, symbols);
end function;

/* Show information about a symbol when we hover the cursor over it
 * See: https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#textDocument_hover
 * Parameters: textDocument, position, (optional) workDoneToken
 * Returns: contents, (optional) range
 */
define function handle-textDocument/hover(session :: <session>,
                                          id :: <object>,
                                          params :: <object>) => ()
  // TODO this is only a dummy
  let text-document = params["textDocument"];
  let uri = text-document["uri"];
  let position = params["position"];
  let (line, column) = decode-position(position);
  let doc = $documents[uri];
  let symbol = symbol-at-position(doc, line, column);
  if (symbol)
    let txt = format-to-string("textDocument/hover %s (%d/%d)", symbol, line + 1, column + 1);
    let hover = json("contents", make-markup(txt, markdown: #f));
    send-response(session, id, hover);
  else
    // No symbol found (probably out of range)
    send-response(session, id, #f);
  end;
end function;

define function handle-textDocument/didOpen(session :: <session>,
                                            id :: <object>,
                                            params :: <object>) => ()
  // TODO this is only a dummy
  let textDocument = params["textDocument"];
  let uri = textDocument["uri"];
  let languageId = textDocument["languageId"];
  let version = textDocument["version"];
  let text = textDocument["text"];
  local-log("textDocument/didOpen: File %s of type %s, version %s, length %d",
            uri, languageId, version, size(text));
  // Only bother about dylan files for now.
  if (languageId = "dylan")
    register-file(uri, text);
  end if;
  if (*project*)
    // This is just test code.
    // Let's see if we can find a module
    let u = as(<url>, uri);
    let f = make-file-locator(u);
    let (m, l) = file-module(*project*, f);
    local-log("textDocument/didOpen: File: %= Module: %=, Library: %=",
              as(<string>, f),
              if (m) environment-object-primitive-name(*project*, m) end,
              if (l) environment-object-primitive-name(*project*, l) end);
  else
    local-log("textDocument/didOpen: no project found");
  end if;
end function;

// Go to definition.
// Sent by M-. (emacs), ??? (VSCode).
// See https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#textDocument_definition
// Example JSON:
//   { "jsonrpc": "2.0",
//     "method": "textDocument/definition",
//     "params": {
//         "textDocument": {
//             "uri": "file:///home/cgay/dylan/workspaces/lsp/lsp-dylan/testproject/testproject.dylan"
//         },
//         "position": { "line": 9, "character": 16}
//     },
//     "id": 2
//   }
define function handle-textDocument/definition
    (session :: <session>, id :: <object>, params :: <object>) => ()
  let text-document = params["textDocument"];
  let uri = text-document["uri"];
  let position = params["position"];
  let (line, character) = decode-position(position);
  let doc = element($documents, uri, default: #f);
  let location = $null;
  if (~doc)
    local-log("textDocument/definition: document not found: %=", uri);
  else
    unless (doc.document-module)
      let local-dir = make(<directory-locator>, path: locator-path(doc.document-uri));
      let local-file = make(<file-locator>,
                            directory: local-dir,
                            name: locator-name(doc.document-uri));
      let (mod, lib) = file-module(*project*, local-file);
      local-log("textDocument/definition: module=%s, library=%s", mod, lib);
      doc.document-module := mod;
    end;
    let symbol = symbol-at-position(doc, line, character);
    if (symbol)
      let (target, line, char)
        = lookup-symbol(session, symbol, module: doc.document-module);
      if (target)
        local-log("textDocument/definition: Lookup %s and got target=%s, line=%d, char=%d",
                  symbol, target, line, char);
        let uri = make-file-uri(target); // TODO
        location := make-location(as(<string>, uri), line, char);
      else
        local-log("textDocument/definition: symbol %=, not found", symbol);
      end;
    else
      local-log("textDocument/definition: symbol is #f, nothing to lookup", symbol);
      show-info(session, "No symbol found at current position.");
    end;
  end;
  send-response(session, id, location);
end function;

define function handle-workspace/didChangeConfiguration(session :: <session>,
                                            id :: <object>,
                                                        params :: <object>) => ()
  // NOTE: vscode always sends this just after initialized, whereas
  // emacs does not, so we need to ask for config items ourselves and
  // not wait to be told.
  local-log("Did change configuration");
  local-log("Settings: %s", print-json-to-string(params));
  // TODO do something with this info.
  let settings = params["settings"];
  let dylan-settings = settings["dylan"];
  let project-name = element(dylan-settings, "project", default: #f);
  *project-name* := (project-name ~= "") & project-name;
  //show-info(session, "The config was changed");
  test-open-project(session);
end function;

define function trailing-slash(s :: <string>) => (s-with-slash :: <string>)
  if (s[s.size - 1] = '/')
    s
  else
    concatenate(s, "/")
  end
end;

/* Handler for 'initialized' message.
 *
 * Example: {"jsonrpc":"2.0","method":"initialized","params":{}}
 *
 * Here we will register the dynamic capabilities of the server with the client.
 * Note we don't do this yet, any capabilities are registered statically in the
 * 'initialize' message.
 * Here also we will start the compiler session.
 */
define function handle-initialized
    (session :: <session>, id :: <object>, params :: <object>) => ()
  /* Commented out because we don't need to do this (yet)
  let hregistration = json("id", "dylan-reg-hover",
                           "method", "textDocument/hover");
  let oregistration = json("id", "dylan-reg-open",
                           "method", "textDocument/didOpen");

  send-request(session, "client/registerCapability", json("registrations", list(hregistration, oregistration)),
               callback: method(session, params)
                           local-log("Callback called back..%s", session);
                           show-info(session, "Thanks la")
                         end);
*/
  show-info(session, "Dylan LSP server started.");
  let in-stream = make(<string-stream>);
  let out-stream = make(<string-stream>, direction: #"output");

  // Test code
  for (var in list("OPEN_DYLAN_RELEASE",
                   "OPEN_DYLAN_RELEASE_BUILD",
                   "OPEN_DYLAN_RELEASE_INSTALL",
                   "OPEN_DYLAN_RELEASE_REGISTRIES",
                   "OPEN_DYLAN_USER_BUILD",
                   "OPEN_DYLAN_USER_INSTALL",
                   "OPEN_DYLAN_USER_PROJECTS",
                   "OPEN_DYLAN_USER_REGISTRIES",
                   "OPEN_DYLAN_USER_ROOT",
                   "PATH"))
    local-log("handle-initialized: %s=%s", var, environment-variable(var));
  end;
  send-request(session, "workspace/workspaceFolders", #f,
               callback: handle-workspace/workspaceFolders);
  *server* := start-compiler(in-stream, out-stream);
  test-open-project(session);
end function handle-initialized;

define function test-open-project(session) => ()
  let project-name = find-project-name();
  local-log("test-open-project: Found project name %=", project-name);
  *project* := open-project(*server*, project-name);
  local-log("test-open-project: Project opened");

  // Let's see if we can find a module.

  // TODO(cgay): file-module is returning #f because (I believe)
  // project-compiler-database(*project*) returns #f and hence file-module
  // punts. Not sure who's responsible for opening the db and setting that slot
  // or why it has worked at all in the past.
  let (m, l) = file-module(*project*, "library.dylan");
  local-log("test-open-project: m = %=, l = %=", m, l);
  local-log("test-open-project: Try Module: %=, Library: %=",
            m & environment-object-primitive-name(*project*, m),
            l & environment-object-primitive-name(*project*, l));

  local-log("test-open-project: project-library = %=", project-library(*project*));
  local-log("test-open-project: project db = %=", project-compiler-database(*project*));

  *module* := m;
  if (*project*)
    let warn = curry(log-warning, $log, "open-project-compiler-database: %=");
    let db = open-project-compiler-database(*project*, warning-callback: warn);
    local-log("test-open-project: db = %=", db);
    for (s in project-sources(*project*))
      let rl = source-record-location(s);
      local-log("test-open-project: Source: %=, a %= in %=",
                s,
                object-class(s),
                as(<string>, rl));
    end;
    local-log("test-open-project: listing project file libraries:");
    do-project-file-libraries(method (l, r)
                                local-log("test-open-project: Lib: %= Rec: %=", l, r);
                              end,
                              *project*,
                              as(<file-locator>, "library.dylan"));
  else
    local-log("test-open-project: project did't open");
  end if;
  local-log("test-open-project: Compiler started: %=, Project %=", *server*, *project*);
  local-log("test-open-project: Database: %=", project-compiler-database(*project*));
end function;

define function ensure-trailing-slash(s :: <string>) => (s-slash :: <string>)
  if (ends-with?(s, "/"))
    s
  else
    concatenate(s, "/")
  end;
end function;

/* Handle the 'initialize' message.
 * Here we initialize logging/tracing and store the workspace root for later.
 * Here we return the 'static capabilities' of this server.
 * In the future we can register capabilities dynamically by sending messages
 * back to the client; this seems to be the preferred 'new' way to do things.
 * https://microsoft.github.io/language-server-protocol/specifications/specification-3-15/#initialize
*/
define function handle-initialize (session :: <session>,
                                   id :: <object>,
                                   params :: <object>) => ()
  // The very first received message is "initialize" (I think), and it seems
  // that for some reason it doesn't get logged, so log params here. The params
  // for this method are copious, so we log them with pretty printing.
  local-log("handle-initialize(%=, %=, %s)",
            session, id,
            with-output-to-string (s)
              print-json(params, s, indent: 2)
            end);
  let trace = element(params, "trace", default: "off");
  select (trace by \=)
    "off" => begin
               *trace-messages* := #f;
               *trace-verbose* := #f;
             end;
    "messages" => begin
                    *trace-messages* := #t;
                    *trace-verbose* := #f;
                  end;
    "verbose" => begin
                   *trace-messages* := #t;
                   *trace-verbose* := #t;
                 end;
    otherwise =>
      log-error($log, "handle-initialize: trace must be"
                  " \"off\", \"messages\" or \"verbose\", not %=", trace);
  end select;
  local-log("handle-initialize: debug: %s, messages: %s, verbose: %s",
            *debug-mode*, *trace-messages*, *trace-verbose*);

  // Save the workspace root (if provided) for later.
  // rootUri takes precedence over rootPath if both are provided.
  // TODO: can root-uri be something that's not a file:// URL?
  let root-uri  = element(params, "rootUri", default: #f);
  let root-path = element(params, "rootPath", default: #f);
  session.root := find-workspace-root(root-uri, root-path);
  if (session.root)
    working-directory() := session.root;
  end;
  local-log("handle-initialize: Working directory is now %s", working-directory());

  // Return the capabilities of this server
  let capabilities = json("hoverProvider", #f,
                          "textDocumentSync", 1,
                          "definitionProvider", #t,
                          "workspaceSymbolProvider", #t);
  let response-params = json("capabilities", capabilities);
  send-response(session, id, response-params);
  // All OK to proceed.
  session.state := $session-active;
end function;

// Find the workspace root. The "rootUri" LSP parameter takes precedence over
// the deprecated "rootPath" LSP parameter. We first look for a `dylan-tool`
// workspace root containing the file and then fall back to the nearest
// directory containing a `registry` directory. This should work for
// `dylan-tool` users and others equally well.
define function find-workspace-root
    (root-uri, root-path) => (root :: false-or(<directory-locator>))
  let directory
    = if (root-uri)
        let url = as(<url>, ensure-trailing-slash(root-uri));
        make(<directory-locator>, path: locator-path(url))
      elseif (root-path)
        as(<directory-locator>, root-path)
      end;
  let workspace = ws/workspace-file() & ws/find-workspace(directory: directory);
  if (workspace)
    ws/workspace-directory(workspace)
  else
    // Search up from `directory` to find the directory containing the
    // "registry" directory.
    iterate loop (dir = directory)
      if (dir)
        let registry-dir = subdirectory-locator(dir, "registry");
        if (file-exists?(registry-dir))
          dir
        else
          loop(dir.locator-directory)
        end
      end
    end
  end
end function;

define function handle-workspace/workspaceFolders (session :: <session>,
                                                   params :: <object>)
 => ()
// TODO: handle multi-folder workspaces.
  local-log("Workspace folders were received");
end;

// Maps URI strings to <open-document> objects.
define constant $documents = make(<string-table>);

// Represents one open file (given to us by textDocument/didOpen)
define class <open-document> (<object>)
  constant slot document-uri :: <url>,
    required-init-keyword: uri:;
  slot document-module :: false-or(<module-object>) = #f,
    init-keyword: module:;
  slot document-lines :: <sequence>,
    required-init-keyword: lines:;
end class;

define function register-file (uri, contents)
  let lines = split-lines(contents);
  let doc = make(<open-document>, uri: as(<url>, uri), lines: lines);
  $documents[uri] := doc;
end function;

// Characters that are part of the Dylan "name" BNF.
define constant $dylan-name-characters
  = "abcdefghijklmnopqrstuvwxyzABCDEFGHIHJLKMNOPQRSTUVWXYZ0123456789!&*<>|^$%@_-+~?/=";

// Given a document and a position, find the Dylan name (identifier) that is at
// (or immediately precedes) this position. If the position is, for example,
// the open paren following a function name, we should still find the name. If
// there is no name at position, return #f.
define function symbol-at-position
    (doc :: <open-document>, line, column) => (symbol :: false-or(<string>))
  if (line >= 0
        & line < size(doc.document-lines)
        & column >= 0
        & column < size(doc.document-lines[line]))
    let line = doc.document-lines[line];
    local method name-character?(c) => (well? :: <boolean>)
            member?(c, $dylan-name-characters)
          end;
    let symbol-start = column;
    let symbol-end = column;
    while (symbol-start > 0 & name-character?(line[symbol-start - 1]))
      symbol-start := symbol-start - 1;
    end;
    while (symbol-end < size(line) & name-character?(line[symbol-end]))
      symbol-end := symbol-end + 1;
    end while;
    let name = copy-sequence(line, start: symbol-start, end: symbol-end);
    ~empty?(name) & name
  else
    local-log("line %d column %d not in range for document %s",
              line, column, doc.document-uri);
    #f
  end;
end function;

define function unregister-file(uri)
  // TODO
  remove-key!($documents, uri)
end function;

/*
 * Make a file:// URI from a local file path.
 * This is supposed to follow RFC 8089
 * (locators library not v. helpful here)
 */
define function make-file-uri (f :: <file-locator>)
 => (uri :: <url>)
  if (f.locator-relative?)
    f := merge-locators(f, working-directory());
  end;
  let server = make(<file-server>, host: "");
  let directory = make(<directory-url>,
                       server: server,
                       path: locator-path(f));
  make(<file-url>,
       directory: directory,
       name: locator-name(f))
end;

define function make-file-locator (f :: <url>)
 => (loc :: <file-locator>)
  /* TODO - what if it isnt a file:/, etc etc */
  let d = make(<directory-locator>, path: locator-path(f));
  make(<file-locator>, directory: d, name: locator-name(f))
end;

// Look up a symbol. Return the containing doc,
// the line and column
define function lookup-symbol
    (session, symbol :: <string>, #key module) => (doc, line, column)
  let loc = symbol-location(symbol, module: module);
  if (loc)
    let source-record = loc.source-location-source-record;
    let absolute-path = source-record.source-record-location;
    let (name, line) = source-line-location(source-record,
                                          loc.source-location-start-line);
    let column = loc.source-location-start-column;
    values(absolute-path, line - 1, column)
  else
    local-log("Looking up %s, not found", symbol);
    #f
  end
end;

/* Find the project name to open.
 * Either it is set in the per-directory config (passed in from the client)
 * or we'll guess it is the only lid file in the workspace root.
 * If there is more than one lid file, that's an error, don't return
 * any project.
 * Returns: the name of a project
 *
 * TODO(cgay): Really we need to search the LID files to find the file in the
 *   textDocument/didOpen message so we can figure out which library's project
 *   to open.
 */
define function find-project-name () => (name :: false-or(<string>))
  if (*project-name*)
    // We've set it explicitly
    local-log("Project name explicitly:%s", *project-name*);
    *project-name*
  elseif (ws/workspace-file())
    // There's a dylan-tool workspace.
    let workspace = ws/find-workspace();
    let library-name = workspace & ws/workspace-default-library-name(workspace);
    if (library-name)
      local-log("found dylan-tool workspace default library name %=", library-name);
      library-name
    else
      local-log("dylan-tool workspace has no default library configured.");
      #f
    end;
  else
    // Guess based on there being one .lid file in the workspace root
    block(return)
      local method return-lid(dir, name, type)
              if (type = #"file")
                let file = as(<file-locator>, name);
                if (locator-extension(file) = "lid")
                  return(name);
                end if;
              end if;
            end method;
      do-directory(return-lid, working-directory());
      local-log("find-project-name found no LID files");
      #f
    end block
  end if
end function;

define function main
    (name :: <string>, arguments :: <vector>)
  //one-off-debug();

  // Command line processing
  if (member?("--debug", arguments, test: \=))
    *debug-mode* := #t;
  end if;
  // Set up.
  let msg = #f;
  let retcode = 1;
  let session = make(<stdio-session>);
  // Pre-init state
  while (session.state == $session-preinit)
    local-log("main: state = pre-init");
    let (meth, id, params) = receive-message(session);
    select (meth by =)
      "initialize" => handle-initialize(session, id, params);
      "exit" => session.state := $session-killed;
      otherwise =>
        // Respond to any request with an error, and drop any notifications
        if (id)
          send-error-response(session, id, $server-not-initialized);
        end if;
    end select;
    flush(session);
  end while;
  // Active state
  while (session.state == $session-active)
    local-log("main: state = active");
    let (meth, id, params) = receive-message(session);
    select (meth by =)
      // TODO(cgay): It would be nice to turn params into a set of keyword/value
      // pairs and apply(the-method, session, id, params) so that the parameters
      // to each method are clear from the #key parameters.
      "initialize" =>
          send-error-response(session, id, $invalid-request);
      "initialized" => handle-initialized(session, id, params);
      "workspace/symbol" => handle-workspace/symbol(session, id, params);
      "textDocument/hover" => handle-textDocument/hover(session, id, params);
      "textDocument/didOpen" => handle-textDocument/didOpen(session, id, params);
      "textDocument/definition" => handle-textDocument/definition(session, id, params);
      "workspace/didChangeConfiguration" => handle-workspace/didChangeConfiguration(session, id, params);
      // TODO handle all other messages here
      "shutdown" =>
        begin
          // TODO shutdown everything
          send-response(session, id, $null);
          session.state := $session-shutdown;
        end;
      "exit" => session.state := $session-killed;
      otherwise =>
      // Respond to any other request with an not-implemented error.
      // Drop any other notifications
        begin
          local-log("main: %s '%s' is not implemented",
                    if (id)
                      "Request"
                    else
                      "Notification"
                    end,
                    meth);
          if (id)
            send-error-response(session, id, $method-not-found);
          end if;
        end;
    end select;
    flush(session);
  end while;
  // Shutdown state
  while (session.state == $session-shutdown)
    local-log("main: state = shutdown");
    let (meth, id, params)  = receive-message(session);
    select (meth by =)
      "exit" =>
        begin
          retcode := 0;
          session.state := $session-killed;
        end;
      otherwise =>
        // Respond to any request with an invalid error,
        // Drop any notifications
        begin
          if (id)
            send-error-response(session, id, $invalid-request);
          end if;
        end;
    end select;
    flush(session);
  end while;

  exit-application(retcode);
end function main;

ignore(*library*, run-compiler, describe-symbol, list-all-package-names,
       document-lines-setter, trailing-slash, unregister-file,
       one-off-debug, dump, show-warning, show-log, show-error);

main(application-name(), application-arguments());



// Local Variables:
// indent-tabs-mode: nil
// End:
