## BrowserDriver test — assert that scripted clicks compile to the expected
## Playwright JSON command.

import std/[json, unittest]
import ../src/gui_assert/parser
import ../src/gui_assert/driver

suite "browser driver Playwright emission":

  test "emitClick produces the expected JSON command":
    let driver = newBrowserDriver(defaultTimeoutMs = 30000)
    let cmd = driver.emitClick(target = "#play", at = 5.0)
    check cmd["type"].getStr == "click"
    check cmd["selector"].getStr == "#play"
    check cmd["button"].getStr == "left"
    check cmd["at"].getFloat == 5.0
    check cmd["timeout"].getInt == 30000

  test "script compiles to a sequence of Playwright commands":
    const yaml = """
timeline:
  - time: 1.0
    action: click
    params:
      target: "#play"
  - time: 2.5
    action: scroll
    params:
      target: ".monaco-editor"
      deltaY: 120
  - time: 3.0
    action: type_text
    params:
      target: "input#search"
      text: "fibonacci"
      wpm: 90
  - time: 4.0
    action: navigate
    params:
      url: "https://example.invalid/start"
"""
    let driver = newBrowserDriver(defaultTimeoutMs = 5000)
    let script = parseScriptYaml(yaml)
    let cmds = scriptToBrowserCommands(driver, script)
    check cmds.len == 4

    check cmds[0]["type"].getStr == "click"
    check cmds[0]["selector"].getStr == "#play"
    check cmds[0]["at"].getFloat == 1.0

    check cmds[1]["type"].getStr == "scroll"
    check cmds[1]["selector"].getStr == ".monaco-editor"
    check cmds[1]["deltaY"].getFloat == 120.0
    check cmds[1]["at"].getFloat == 2.5

    check cmds[2]["type"].getStr == "type"
    check cmds[2]["selector"].getStr == "input#search"
    check cmds[2]["text"].getStr == "fibonacci"
    check cmds[2]["wpm"].getInt == 90
    check cmds[2]["at"].getFloat == 3.0

    check cmds[3]["type"].getStr == "navigate"
    check cmds[3]["url"].getStr == "https://example.invalid/start"
    check cmds[3]["at"].getFloat == 4.0
