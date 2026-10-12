# Realistic Resistances - source

A Bingus Shared Loader Lua mod: `core.lua` does all the work; the option addons only set flags that the core reads.

    core.lua        the mod (finds what it needs in the game's code at start-up; tester-only parts are marked
                    --@tester-begin / --@tester-end and are left out of the release build; research-only parts
                    are marked --@research-begin / --@research-end and are kept only in numbered test builds)
    build.py        builds the mod zips (Python 3 + Pillow):
                      python3 build.py release   -> Realistic-Resistances-<ver>.zip and the -Tester.zip
                      python3 build.py test N    -> a numbered test build (logs to Logs\test)
                    every archive is read back after it is written, and the manifest and every Lua file are
                    checked for personal paths
    art/art.py      thumbnail, header, gallery, values sheet, AyakaMods cover, GitHub social preview and the option icons
                    (Playwright Chromium, Anton + Barlow Condensed in art/fonts)

Run both from this folder.
