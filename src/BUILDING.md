# Realistic Resistances - source

A Bingus Shared Loader Lua mod: `core.lua` does all the work; the option addons only set flags that the core reads.

    core.lua        the mod (finds what it needs in the game's code at start-up; tester-only parts are marked
                    --@tester-begin / --@tester-end and are left out of the release build)
    build.py        builds the mod zips (Python 3 + Pillow):
                      python3 build.py release   -> Realistic-Resistances-<ver>.zip and the -Tester.zip
                      python3 build.py test N    -> a numbered test build (logs to Logs\test)
    art/art.py      thumbnail, header, gallery, values sheet, GitHub social preview and the option icons
                    (Playwright Chromium, Anton + Barlow Condensed in art/fonts)

Run both from this folder.
