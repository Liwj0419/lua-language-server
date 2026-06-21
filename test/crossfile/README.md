# Cross-file Test Notes

Run this suite with:

```sh
bin/lua-language-server test.lua --name=crossfile
```

## Global module alias completion

`completion.lua` covers the case where a file such as `datautils.lua`
returns a table, another file assigns the unresolved global `datautils` to a
global field, and completion is requested from that field:

```lua
g = {}
g.data = datautils

g.data.
```

The expected behavior is that `g.data` uses the table returned by
`datautils.lua` for member completion. This verifies that cross-file
completion can follow a global field alias to a same-name module file even
when the project code does not call `require 'datautils'` at the assignment.
