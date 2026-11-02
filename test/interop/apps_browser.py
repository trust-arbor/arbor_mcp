"""Qualify the real example View against the official Apps bridge in Chromium."""
import json
from pathlib import Path
import sys
from playwright.sync_api import sync_playwright, expect

origin, output = sys.argv[1:3]
destination = Path(output)
destination.mkdir(parents=True, exist_ok=True)
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    try:
        page = browser.new_page(viewport={"width": 1100, "height": 950})
        failures = []
        page.on("pageerror", lambda error: failures.append(str(error)))
        page.goto(origin)
        page.wait_for_load_state("networkidle")
        view = page.frame_locator("#view").frame_locator("iframe")
        expect(view.locator("#total")).to_have_text("$164", timeout=15000)
        expect(view.locator("#view-label")).to_have_text("Local estimate")
        expect(view.get_by_role("button", name="Update estimate")).to_be_enabled()
        assert page.locator("#model-tools").inner_text() == "plan, plan_policy"
        assert "Local estimate" not in page.locator("#model-result").inner_text()
        view.locator("body").screenshot(path=str(destination / "light.png"))
        # Verify actual input handling before a result, and round-trip a non-step-25 value.
        args = {"seats": 9, "storageGb": 123}
        page.evaluate("args => window.testHost.sendInput(args)", args)
        expect(view.locator("#seats")).to_have_value("9")
        expect(view.locator("#storage")).to_have_value("123")
        expect(view.locator("#storage-label")).to_have_text("123 GB")
        expect(view.locator("#status")).to_have_text("Calculating your estimate…")
        expect(view.get_by_role("button", name="Update estimate")).to_be_disabled()
        page.evaluate("args => window.testHost.completePlan(args)", args)
        expect(view.locator("#total")).to_have_text("$186.6")
        view.get_by_role("button", name="Update estimate").click()
        expect(view.locator("#status")).to_have_text("Estimate updated. Make it your own.")
        expect(view.locator("#total")).to_have_text("$186.6")
        expect(view.locator("#summary")).to_contain_text("123 GB")
        view.locator("#seats").evaluate("el => {el.value='12'; el.dispatchEvent(new Event('input', {bubbles:true}));}")
        view.locator("#storage").evaluate("el => {el.value='200'; el.dispatchEvent(new Event('input', {bubbles:true}));}")
        view.get_by_role("button", name="Update estimate").click()
        expect(view.locator("#total")).to_have_text("$256")
        expect(view.locator("#summary")).to_contain_text("12 seats")
        assert view.locator("body").evaluate("""() => {
          try { void window.top.document.body; return false; }
          catch (error) { return error.name === 'SecurityError'; }
        }""")
        # Positive reachability/CORS control, then actual CSP violation and zero network delivery.
        target = origin + "/csp-probe"
        assert page.evaluate("url => fetch(url).then(r => r.text())", target) == "reachable"
        before = page.request.get(origin + "/counts").json()
        assert before["foreignReady"] and before["registeredForeign"] == "other_server__update_plan"
        blocked = view.locator("body").evaluate("""async (_, url) => {
          const violation = new Promise(resolve => document.addEventListener('securitypolicyviolation', event => {
            if (event.effectiveDirective === 'connect-src' && event.blockedURI === url) resolve(true);
          }));
          try { await fetch(url); return false; }
          catch { return await violation; }
        }""", target)
        assert blocked
        assert page.request.get(origin + "/counts").json()["probeRequests"] == before["probeRequests"]
        # Forge valid View RPC requests to verify host-side visibility and connection binding.
        for name in ["plan_policy", "other_server__update_plan"]:
            response = view.locator("body").evaluate("""(_, name) => new Promise(resolve => {
              const id = 'negative-' + name;
              const receive = event => { if (event.data?.id === id) {window.removeEventListener('message', receive); resolve(event.data);} };
              window.addEventListener('message', receive);
              window.parent.postMessage({jsonrpc:'2.0', id, method:'tools/call', params:{name, arguments:{}}}, '*');
            })""", name)
            assert "error" in response
        counts = page.request.get(origin + "/counts").json()
        assert counts["forwarded"] == ["plan", "update_plan", "update_plan"]
        assert counts["foreignForwarded"] == []
        page.evaluate("window.testHost.setTheme('dark')")
        expect(view.locator("html")).to_have_attribute("data-theme", "dark")
        view.locator("body").screenshot(path=str(destination / "dark.png"))
        page.set_viewport_size({"width": 390, "height": 1000})
        expect(view.locator("#total")).to_have_text("$256")
        view.locator("body").screenshot(path=str(destination / "mobile.png"))
        sizes = page.evaluate("window.testHost.sizeChanges()")
        assert sizes > 0
        assert not failures, failures
        assert page.evaluate("window.testHost.teardown()")
        expect(page.locator("#view")).to_have_count(0)
        print(json.dumps({"initial": "$164", "updated": "$256", "isolated": True,
                          "csp_blocked": True, "visibility_checked": True,
                          "size_changes": sizes, "teardown": True, "screenshots": 3}))
    except Exception:
        page.screenshot(path=str(destination / "failure.png"), full_page=True)
        print("Browser errors:", failures, "status:", view.locator("#status").inner_text(), "counts:", page.request.get(origin+"/counts").json(), file=sys.stderr)
        raise
    finally:
        browser.close()
