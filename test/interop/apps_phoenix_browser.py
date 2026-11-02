"""Exercise the shipped Phoenix/LiveView host with two actual browser tabs."""
import json
from pathlib import Path
import sys
from playwright.sync_api import sync_playwright, expect

origin, sandbox_origin, output = sys.argv[1:4]
destination = Path(output)
destination.mkdir(parents=True, exist_ok=True)


def app_frame(page):
    return page.frame_locator("#mcp-app-view").frame_locator("iframe")


def rpc(view, method, params):
    return view.locator("body").evaluate("""(_, {method, params}) => new Promise(resolve => {
      const id = 'host-check-' + crypto.randomUUID();
      const receive = event => {
        if (event.data?.id === id) { window.removeEventListener('message', receive); resolve(event.data); }
      };
      window.addEventListener('message', receive);
      window.parent.postMessage({jsonrpc:'2.0', id, method, params}, '*');
    })""", {"method": method, "params": params})


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    pages = []
    errors = []
    try:
        context = browser.new_context(viewport={"width": 1440, "height": 1100})
        context.add_init_script("""(() => {
          const NativeSocket = window.WebSocket;
          window.WebSocket = class extends NativeSocket {
            constructor(...args) { super(...args); if (String(args[0]).includes('/live/websocket')) window.__observedSocket = this; }
          };
        })();""")
        page = context.new_page()
        pages.append(page)
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(origin)
        page.wait_for_load_state("networkidle")
        expect(page.locator("#connection-status")).to_contain_text("Connected", timeout=15000)
        assert page.locator(".tool-button").count() == 2
        expect(page.locator("#tool-update_plan")).to_have_count(0)
        expect(page.get_by_text("Make space for a tool.")).to_be_visible()
        page.screenshot(path=str(destination / "empty.png"), full_page=True)
        page.locator("#tool-plan").click()
        view = app_frame(page)
        expect(view.locator("#total")).to_have_text("$164", timeout=15000)
        expect(view.locator("#view-label")).to_have_text("Local estimate")
        expect(page.locator("#model-context")).to_contain_text("$164.00")
        assert "Local estimate" not in page.locator("#model-context").inner_text()
        expect(page.locator("#mcp-app-view")).to_have_attribute("sandbox", "allow-scripts allow-same-origin")
        expect(page.locator("#mcp-app-view")).to_have_attribute("src", sandbox_origin)
        page.screenshot(path=str(destination / "light.png"), full_page=True)

        view.locator("#storage").evaluate("el => {el.value='123';el.dispatchEvent(new Event('input', {bubbles:true}));}")
        view.get_by_role("button", name="Update estimate").click()
        expect(view.locator("#total")).to_have_text("$168.6")
        expect(view.locator("#summary")).to_contain_text("123 GB")
        expect(page.locator("#activity")).to_contain_text("View → tools/call")
        # UI-only updates do not silently replace the model-facing result.
        expect(page.locator("#model-context")).to_contain_text("$164.00")
        result = rpc(view, "resources/read", {"uri": "ui://arbor/plan.html"})
        assert result["result"]["contents"][0]["mimeType"] == "text/html;profile=mcp-app"
        for method, params in [
            ("tools/call", {"name": "plan_policy", "arguments": {}}),
            ("tools/call", {"name": "unknown_server__update_plan", "arguments": {}}),
            ("resources/read", {"uri": "ui://other/not-registered"}),
            ("ui/open-link", {"url": "https://example.com"}),
        ]:
            assert "error" in rpc(view, method, params)
        assert view.locator("body").evaluate("""() => {
          try { void window.top.document.body; return false; } catch (e) { return e.name === 'SecurityError'; }
        }""")
        target = origin + "/assets/host.css?csp-probe=1"
        assert page.request.get(target).status == 200
        assert view.locator("body").evaluate("""async (_, url) => {
          const violation = new Promise(resolve => document.addEventListener('securitypolicyviolation', event => {
            if (event.effectiveDirective === 'connect-src' && event.blockedURI === url) resolve(true);
          }));
          try { await fetch(url, {mode:'no-cors'}); return false; }
          catch { return await violation; }
        }""", target)
        page.locator("#tool-plan_policy").click()
        expect(page.locator("#model-context")).to_contain_text("Illustrative pricing only")
        expect(view.locator("#total")).to_have_text("$168.6")
        page.locator("#theme-toggle").click()
        expect(view.locator("html")).to_have_attribute("data-theme", "dark")
        page.screenshot(path=str(destination / "dark.png"), full_page=True)

        # LiveView reconnect mounts a new owner/client and retires the old View.
        page.evaluate("window.__retiredSocket = window.__observedSocket; window.__retiredSocket.close(1000, 'reconnect qualification')")
        page.wait_for_function("() => window.__observedSocket !== window.__retiredSocket && window.__observedSocket.readyState === 1")
        expect(page.locator("#connection-status")).to_contain_text("Connected")
        expect(page.locator("html")).to_have_attribute("data-theme", "light")
        expect(page.locator("#mcp-app-view")).to_have_count(0)
        page.locator("#tool-plan").click()
        expect(app_frame(page).locator("#total")).to_have_text("$164")

        other = context.new_page()
        other.set_viewport_size({"width": 1000, "height": 950})
        pages.append(other)
        other.goto(origin)
        other.wait_for_load_state("networkidle")
        expect(other.locator("#connection-status")).to_contain_text("Connected")
        other.locator("#tool-plan").click()
        expect(app_frame(other).locator("#total")).to_have_text("$164")
        page.locator("#close-view").click()
        expect(page.locator("#mcp-app-view")).to_have_count(0)
        expect(app_frame(other).locator("#total")).to_have_text("$164")
        page.locator("#tool-plan").click()
        expect(app_frame(page).locator("#total")).to_have_text("$164")
        expect(page.locator("#mcp-app-view")).to_have_count(1)
        page.set_viewport_size({"width": 390, "height": 1000})
        expect(app_frame(page).locator("#total")).to_have_text("$164")
        page.screenshot(path=str(destination / "mobile.png"), full_page=True)
        page.close()
        pages.remove(page)
        remaining = app_frame(other)
        remaining.locator("#seats").evaluate("el => {el.value='12';el.dispatchEvent(new Event('input', {bubbles:true}));}")
        remaining.get_by_role("button", name="Update estimate").click()
        expect(remaining.locator("#total")).to_have_text("$236")
        assert not errors, errors
        other.close()
        pages.remove(other)
        print(json.dumps({"phoenix": True, "tabs": 2, "updated": "$168.6", "sandbox": True,
                          "csp": True, "visibility": True, "reopened": True, "reconnected": True, "screenshots": 4}))
    except Exception:
        for i, item in enumerate(pages):
            if not item.is_closed():
                item.screenshot(path=str(destination / f"failure-{i}.png"), full_page=True)
        print("Browser errors:", errors, file=sys.stderr)
        raise
    finally:
        browser.close()
