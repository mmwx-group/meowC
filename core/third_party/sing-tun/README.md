# sing-tun

Simple transparent proxy library.

For Linux, Windows, macOS and iOS.

## License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```
---

**meowC:** vendored copy of `github.com/metacubex/sing-tun` v0.4.28 (GPL-3.0, see LICENSE), used via
`replace` in `core/go.mod`. Only change: `stack_system.go` `acceptLoop` keeps accepting after
transient errors instead of returning (see the comment there).
