# Copyright 2011 Revolution Analytics
#    
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#some option formatting utils

paste.options = function(...) {
  optlist = 
    unlist(
      sapply(
        list(...), 
        function(x) { 
          if (is.null(x)) {NULL}
          else {
            if (is.logical(x)) {
              if(x) "" else NULL} 
            else x }}))
  if(is.null(optlist)) "" 
  else 
    paste(
    " ",
    unlist(
      rbind(
        paste(
          "-", 
          names(optlist), 
          sep = ""), 
        optlist)), 
    " ",
    collapse = " ")}

make.input.files = function(infiles) {
  if(length(infiles) == 0) return(" ")
  paste(sapply(infiles, 
               function(r) {
                 paste.options(input = r)}), 
        collapse=" ")}

## loops section, or what runs on the nodes

activate.profiling = function() {
  dir = file.path("/tmp/Rprof", Sys.getenv('mapred_job_id'), Sys.getenv('mapred_tip_id'))
  dir.create(dir, recursive = T)
  Rprof(file.path(dir, paste(Sys.getenv('mapred_task_id'), Sys.time())))}

close.profiling = function() Rprof(NULL)


map.loop = function(map, keyval.reader, keyval.writer, profile) {
  if(profile) activate.profiling()
  kv = keyval.reader()
  while(!is.null(kv)) { 
    out = map(keys(kv), values(kv))
    if(!is.null(out)) {
      keyval.writer(as.keyval(out))}
    kv = keyval.reader()}
  if(profile) close.profiling()
  invisible()}

list.cmp = function(ll, e) sapply(ll, function(l) isTRUE(all.equal(e, l, check.attributes = FALSE)))
## using isTRUE(all.equal(x)) because identical() was too strict, but on paper it should be it

reduce.loop = function(reduce, keyval.reader, keyval.writer, profile) {
  reduce.flush = function(current.key, vv) {
    out = reduce(current.key, c.or.rbind(vv))
    if(!is.null(out)) keyval.writer(as.keyval(out))}
  if(profile) activate.profiling()
  kv = keyval.reader()
  current.key = NULL
  vv = make.fast.list()
  while(!is.null(kv)) {
    apply.keyval(
      kv,
      function(k,v) {
        if(length(vv()) == 0) { #start
          current.key <<- k
          vv(list(v))}
        else { #accumulate
          if(identical(k, current.key)) vv(list(v))
          else { #flush
            reduce.flush(current.key, vv())
            current.key <<- k
            vv <<- make.fast.list(list(v))}}})
    kv = keyval.reader()}
  if(length(vv()) > 0) reduce.flush(current.key, vv())
  if(profile) close.profiling()
  invisible()
}

# the main function for the hadoop backend

hadoop.cmd = function() {
  hadoop_cmd = Sys.getenv("HADOOP_CMD")
  if( hadoop_cmd == "") {
    hadoop_home = Sys.getenv("HADOOP_HOME")
    if(hadoop_home == "") stop("Please make sure that the env. variable HADOOP_CMD or HADOOP_HOME are set")
    file.path(hadoop_home, "bin", "hadoop")}
  else hadoop_cmd}

hadoop.streaming = function() {
  hadoop_streaming = Sys.getenv("HADOOP_STREAMING")
  if(hadoop_streaming == ""){
    hadoop_home = Sys.getenv("HADOOP_HOME")
    if(hadoop_home == "") stop("Please make sure that the env. variable HADOOP_STREAMING or HADOOP_HOME are set")
    stream.jar = list.files(path =  file.path(hadoop_home, "contrib", "streaming"), pattern = "jar$", full.names = TRUE)
    paste(hadoop.cmd(), "jar", stream.jar)}
  else paste(hadoop.cmd(), "jar", hadoop_streaming)}

rmr.stream = function(
  map, 
  reduce, 
  combine, 
  in.folder, 
  out.folder, 
  profile.nodes, 
  keyval.length,
  input.format, 
  output.format, 
  backend.parameters, 
  verbose = TRUE, 
  debug = FALSE) {
  ## prepare map and reduce executables
  rmr.local.env = tempfile(pattern = "rmr-local-env")
  rmr.global.env = tempfile(pattern = "rmr-global-env")
  preamble = paste(sep = "", 'options(warn=1)
 
  library(rmr2)
  load("',basename(rmr.local.env),'")
  load("',basename(rmr.global.env),'")
  invisible(lapply(libs, function(l) require(l, character.only = T)))
  
  input.reader = 
    function()
      rmr2:::make.keyval.reader(
        input.format$mode, 
        input.format$format, 
        keyval.length = keyval.length)
  output.writer = 
    function()
      rmr2:::make.keyval.writer(
        output.format$mode, 
        output.format$format)
    
  default.reader = 
    function() 
      rmr2:::make.keyval.reader(
        default.input.format$mode, 
        default.input.format$format, 
        keyval.length = keyval.length)
  default.writer = 
    function() 
      rmr2:::make.keyval.writer(
        default.output.format$mode, 
        default.output.format$format)
 
  ')  
  map.line = '  
  rmr2:::map.loop(
    map = map, 
    keyval.reader = input.reader(), 
    keyval.writer = 
      if(is.null(reduce)) {
        output.writer()}
      else {
        default.writer()},
    profile = profile.nodes)'
  reduce.line  =  '  
  rmr2:::reduce.loop(
    reduce = reduce, 
    keyval.reader = default.reader(), 
    keyval.writer = output.writer(),
    profile = profile.nodes)'
  combine.line = '  
  rmr2:::reduce.loop(
    reduce = combine, 
    keyval.reader = default.reader(),
    keyval.writer = default.writer(), 
  profile = profile.nodes)'

  map.file = tempfile(pattern = "rmr-streaming-map")
  writeLines(c(preamble, map.line), con = map.file)
  reduce.file = tempfile(pattern = "rmr-streaming-reduce")
  writeLines(c(preamble, reduce.line), con = reduce.file)
  combine.file = tempfile(pattern = "rmr-streaming-combine")
  writeLines(c(preamble, combine.line), con = combine.file)
  
  ## set up the execution environment for map and reduce
  if (!is.null(combine) && is.logical(combine) && combine) {
    combine = reduce}
  
  save.env = function(fun = NULL, name) {
    envir = 
      if(is.null(fun)) parent.env(environment()) else {
        if (is.function(fun)) environment(fun)
        else fun}
    save(list = ls(all.names = TRUE, envir = envir), file = name, envir = envir)
    name}
  
  default.input.format = make.input.format("native")
  default.output.format = make.output.format("native", keyval.length = keyval.length)
  
  libs = sub("package:", "", grep("package", search(), value = T))
  image.cmd.line = paste("-file",
                         c(save.env(name = rmr.local.env),
                           save.env(.GlobalEnv, rmr.global.env)),
                         collapse = " ")
  ## prepare hadoop streaming command
  hadoop.command = hadoop.streaming()
  input =  make.input.files(in.folder)
  output = paste.options(output = out.folder)
  input.format.opt = paste.options(inputformat = input.format$streaming.format)
  output.format.opt = paste.options(outputformat = output.format$streaming.format)
  stream.map.input =
    if(input.format$mode == "binary") {
      paste.options(D = "stream.map.input=typedbytes")}
    else {''}
  stream.map.output = 
    if(is.null(reduce) && output.format$mode == "text") "" 
    else   paste.options(D = "stream.map.output=typedbytes")
  stream.reduce.input = paste.options(D = "stream.reduce.input=typedbytes")
  stream.reduce.output = 
    if(output.format$mode == "binary") paste.options(D = "stream.reduce.output=typedbytes")
    else ''
  stream.mapred.io = paste(stream.map.input,
                           stream.map.output,
                           stream.reduce.input,
                           stream.reduce.output)
 
  mapper = paste.options(mapper = paste('"Rscript', basename(map.file), '"'))
  m.fl = paste.options(file = map.file)
  if(!is.null(reduce) ) {
    reducer = paste.options(reducer  = paste('"Rscript', basename(reduce.file), '"'))
    r.fl = paste.options(file = reduce.file)}
  else {
    reducer = ""
    r.fl = "" }
  if(!is.null(combine) && is.function(combine)) {
    combiner = paste.options(combiner = paste('"Rscript', basename(combine.file), '"'))  
    c.fl =  paste.options(file = combine.file)}
  else {
    combiner = ""
    c.fl = "" }
  if(is.null(reduce) && 
    !is.element("mapred.reduce.tasks",
                sapply(strsplit(as.character(named.slice(backend.parameters, 'D')), '='), 
                       function(x)x[[1]])))
    backend.parameters = append(backend.parameters, list(D='mapred.reduce.tasks=0'))
  #debug.opts = "-mapdebug kdfkdfld -reducexdebug jfkdlfkja"
  
  final.command =
    paste(
      hadoop.command, 
      stream.mapred.io,  
      paste.options(backend.parameters), 
      input, 
      output, 
      mapper, 
      combiner,
      reducer, 
      image.cmd.line, 
      m.fl, 
      r.fl, 
      c.fl,
      input.format.opt, 
      output.format.opt, 
      "2>&1")
  if(verbose) {
    retval = system(final.command)
    if (retval != 0) stop("hadoop streaming failed with error code ", retval, "\n")}
  else {
    console.output = tryCatch(system(final.command, intern=TRUE), 
                              warning = function(e) stop(e)) 
    0}}


#hdfs section

hdfs = function(cmd, intern, ...) {
  if (is.null(names(list(...)))) {
    argnames = sapply(1:length(list(...)), function(i) "")}
  else {
    argnames = names(list(...))}
  system(paste(hadoop.cmd(), " dfs -", cmd, " ", 
               paste(
                 apply(cbind(argnames, list(...)), 1, 
                       function(x) paste(
                         if(x[[1]] == "") {""} else {"-"}, 
                         x[[1]], 
                         " ", 
                         to.dfs.path(x[[2]]), 
                         sep = ""))[
                           order(argnames, decreasing = T)], 
                 collapse = " "), 
               sep = ""), 
         intern = intern)}

getcmd = function(matched.call)
  strsplit(tail(as.character(as.list(matched.call)[[1]]), 1), "\\.")[[1]][[2]]

hdfs.match.sideeffect = function(...) {
  hdfs(getcmd(match.call()), FALSE, ...) == 0}

#this returns a character matrix, individual cmds may benefit from additional transformations
hdfs.match.out = function(...) {
  oldwarn = options("warn")[[1]]
  options(warn = -1)
  retval = do.call(rbind, strsplit(hdfs(getcmd(match.call()), TRUE, ...), " +")) 
  options(warn = oldwarn)
  retval}

mkhdfsfun = function(hdfscmd, out)
  eval(parse(text = paste ("hdfs.", hdfscmd, " = hdfs.match.", if(out) "out" else "sideeffect", sep = "")), 
       envir = parent.env(environment()))

for (hdfscmd in c("ls", "lsr", "df", "du", "dus", "count", "cat", "text", "stat", "tail", "help")) 
  mkhdfsfun(hdfscmd, TRUE)

for (hdfscmd in c("mv", "cp", "rm", "rmr", "expunge", "put", "copyFromLocal", "moveFromLocal", "get", "getmerge", 
                  "copyToLocal", "moveToLocal", "mkdir", "setrep", "touchz", "test", "chmod", "chown", "chgrp"))
  mkhdfsfun(hdfscmd, FALSE)