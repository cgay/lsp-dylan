Module: lsp-dylan-impl
Synopsis: Communicaton with the Open Dylan command-line compiler
Author: Peter
Copyright: 2019

// The basis of this code is taken from the dswank module.
// Author:    Andreas Bogk and Hannes Mehnert
// Copyright: Original Code is Copyright (c) 2008-2012 Dylan Hackers; All rights reversed.


define variable *dylan-compiler* :: false-or(<command-line-server>) = #f;
define variable *project* = #f;
define variable *module* = #f;
define variable *library* = #f;
define variable *project-name* = #f;

define function start-compiler
    (input-stream, output-stream) => (server :: <command-line-server>)
  od/make-environment-command-line-server(input-stream: input-stream,
                                          output-stream: output-stream)
end function;

// Execute a single 'command-line' style command on the server
define function run-compiler(server, string :: <string>) => ()
  execute-command-line(server, string);
end function;

// Ask the command line compiler to open a project.
// Param: server - the command line server.
// Param: name - either a library name or a lid file.
// Returns: an instance of <project-object>
define function open-project
    (server, name :: <string>) => (project :: <object>)
  let command = make-command(od/<open-project-command>,
                             server: server.server-context,
                             file: as(<file-locator>, name));
  let project = execute-command(command);
  log-debug("Result of opening %s is %=", name, project);
  log-debug("Result of find %s is %=",
            od/project-name(project),
            od/find-project(od/project-name(project)));
  project
end function;

// Get a symbol's description from the compiler database.
// This is used to implement the 'hover' function.
//
// Parameters:
//  symbol-name - a <string>
//  module - a <module-object> or #f
// Returns:
//  description - a <string> or #f
define function describe-symbol
    (symbol-name :: <string>, #key module) => (description :: false-or(<string>))
  let env = get-environment-object(symbol-name, module: module);
  if (env)
    od/environment-object-description(*project*, env, module)
  end
end function;

// Given a definition, make a list of all the places it is used.
//
// Parameters:
//  object - the <definition-object> to look up.
//  include-self? If true, the list also includes the source record of the passed-in object.
// Returns:
//  A sequence of source records.
define function all-references
    (object :: od/<definition-object>, #key include-self?) => (references :: <sequence>)
  let clients = od/source-form-clients(*project*, object);
  if (include-self?)
    add(clients, object)
  else
    clients
  end if;
end function;

// Given an environment-object, get its source-location
define function get-location
    (object :: od/<environment-object>) => (location :: <source-location>)
  od/environment-object-source-location(*project*, object);
end function;

define function list-all-package-names ()
  local method collect-project
            (dir :: <pathname>, filename :: <string>, type :: <file-type>)
          if (type == #"file")
            if (last(filename) ~= '~')
              log-debug("%s", filename);
            end;
          end;
        end;
  let regs = od/find-registries(as(<string>, target-platform-name()));
  let reg-paths = map(od/registry-location, regs);
  for (reg-path in reg-paths)
    if (file-exists?(reg-path))
      do-directory(collect-project, reg-path);
    end;
  end;
end function;

define method n (x :: od/<environment-object>)
  // for debugging!
  let s = od/print-environment-object-to-string(*project*, x);
  format-to-string("%s%s", object-class(x), s);
end;

define method n (x :: <string>)
  format-to-string("\"%s\"", x)
end;

define method n (x :: <locator>)
  format-to-string("locator:\"%s\"", as(<string>, x))
end;

define method n (x == #f)
  "#f"
end;

define function get-environment-object
    (symbol-name :: <string>, #key module) => (object :: false-or(od/<environment-object>))
  let library = od/project-library(*project*);
  log-debug("%s -> module is %s", symbol-name, n(module));
  od/find-environment-object(*project*, symbol-name,
                             library: library, module: module);
end function;

// Given a definition, find all associated definitions.
// Returns a sequence of <definition-object>s.
define generic all-definitions
  (server :: od/<server>, object :: od/<definition-object>) => (definitions :: <sequence>);

// For most definition objects it's just a list with the thing itself
define method all-definitions
    (server :: od/<server>, object :: od/<definition-object>) => (definitions :: <sequence>)
  list(object)
end method;

// For generic functions it's the GF at the front followed by the GF methods.
define method all-definitions
    (server :: od/<server>, gf :: od/<generic-function-object>) => (definitions :: <sequence>)
  local method source-locations-equal? (def1, def2)
          // Note that there's a source-location-equal? method but it doesn't
          // work for <compiler-range-source-location>s. We should fix that.
          let loc1 = od/environment-object-source-location(server, def1);
          let loc2 = od/environment-object-source-location(server, def2);
          loc1.source-location-source-record = loc2.source-location-source-record
            & loc1.source-location-start-line = loc2.source-location-start-line
            & loc1.source-location-end-line = loc2.source-location-end-line
        end;
  let methods = od/generic-function-object-methods(server, gf);
  // Add gf to the result, but only if it's not an implicitly defined generic
  // function, since that would cause unnecessary prompting for which method
  // when there's only one. Since <generic-function-object>s have no
  // implicit/explicit marker, look for equal source locations.
  if (any?(curry(source-locations-equal?, gf), methods))
    methods
  else
    concatenate(vector(gf), methods) // Put gf first.
  end
end method;

// This makes it possible to modify the OD environment sources with debug-out
// messages and see them in our local logs. debug-out et al are from the
// simple-debugging:dylan module.
define function enable-od-environment-debug-logging ()
  debugging?() := #t;
  // Added most of the sources/environment/ debug-out categories here. --cgay
  debug-parts() := #(#"dfmc-environment-application",
                     #"dfmc-environment-database",
                     #"dfmc-environment-projects",
                     #"environment-debugger",
                     #"environment-profiler",
                     #"environment-protocols",
                     #"lsp",   // our own temp category. debug-out(#"lsp", ...)
                     #"project-manager");
  local method lsp-debug-out (fn :: <function>)
          let (fmt, #rest args) = apply(values, fn());
          // I wish we could log the "part" here, but debug-out drops it.
          apply(log-debug, concatenate("debug-out: ", fmt), args)
        end;
  debug-out-function() := lsp-debug-out;
  // Not yet...
  //*dfmc-debug-out* := #(#"whatever");  // For dfmc-common's debug-out.
end function;
