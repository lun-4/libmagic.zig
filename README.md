# libmagic.zig

## problem statement

libmagic is a cool library, however the path to the default magic database file
can be configured as a build option.

you'd need to create some form of heuristic to find out the system magic file
and hope it works.

this fucks up any attempt at statically linking libmagic

this library came out of this pain, and the want to not depend on any system
libraries. it's hacky, but it works.

tested on
 - `x86_64-linux-gnu`
 - `x86_64-macos-none`

## WARNING

this library contains a 7MB binary blob that is the libmagic database. the
library will write the 7MB blob to a file in your filesystem and reuse it when
possible.

to prevent writing and reading from that file all the time, the heuristics are
still loaded for the system magic file, and if they work, they will be used (
this behavior is overridable by the `loading_mode` in `MimeCookie.init`).

## usage

zigmod supported for now. add the following:

```yaml
  - src: git https://github.com/lun-4/libmagic.zig
```

```zig
const MimeCookie = @import("libmagic.zig").MimeCookie;

// then
var cookie = try MimeCookie.init(allocator, .{}),
defer cookie.deinit();
const mimetype = try self.cookie.inferFile("path/to/my/file/as/a/null/terminated/string");
```
