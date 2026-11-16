#!/usr/bin/env python3
"""CDP target discovery for V2 image-only chats, isolated from editorial."""
import re
import time

def canonical(url):
    return (url or "").split("?", 1)[0].split("#", 1)[0]

# Image-only chats are born independently of the editorial conversation.
# They can appear as a fresh CDP target rather than a navigation on the
# composer tab, and custom-GPT routes may include /g/<slug>/c/<uuid>.
IMAGE_CHAT_RE = re.compile(
    r"^https://chatgpt\.com/(?:c/[A-Za-z0-9-]{16,80}"
    r"|g/[A-Za-z0-9_-]+/c/[A-Za-z0-9-]{16,80})/?$"
)


def image_conversation_urls(browser):
    targets = []
    try:
        cdp = browser.new_browser_cdp_session()
        targets = cdp.send("Target.getTargets").get("targetInfos", [])
        cdp.detach()
    except Exception:
        pass
    urls = {canonical(t.get("url", "")) for t in targets if t.get("type") == "page"}
    for ctx in list(browser.contexts):
        for page in list(ctx.pages):
            urls.add(canonical(page.url))
    return sorted(url for url in urls if IMAGE_CHAT_RE.fullmatch(url))


def verify_image_turn(page, command_id):
    """Only a USER message can prove that this chat owns the image command."""
    try:
        for selector in (
            '[data-message-author-role="user"]',
            '[data-user-message-bubble="true"]',
        ):
            messages = page.locator(selector)
            if messages.count() > 0:
                # ChatGPT can collapse long user prompts or render their
                # visible text asynchronously. The full DOM text of a USER
                # bubble is more dependable than `last.inner_text()`.
                try:
                    if any(command_id in content
                           for content in messages.all_text_contents()):
                        return True
                except Exception:
                    pass
                try:
                    if command_id in messages.last.inner_text(timeout=3000):
                        return True
                except Exception:
                    pass
        body = page.locator("body").inner_text(timeout=3000)
        markers = ("\nYou said:\n", "\nTú dijiste:\n", "\nHas dicho:\n")
        positions = [(body.rfind(marker), marker) for marker in markers]
        start, marker = max(positions, key=lambda pair: pair[0])
        if start < 0:
            return False
        prompt = body[start + len(marker):]
        ends = [prompt.find(marker) for marker in (
            "\nChatGPT said:\n", "\nChatGPT dijo:\n",
            "\nChatGPT ha dicho:\n", "\nChatGPT respondió:\n")]
        if any(i >= 0 for i in ends):
            prompt = prompt[:min(i for i in ends if i >= 0)]
        return command_id in prompt
    except Exception:
        return False


def submission_observation(page, command_id):
    """Safe diagnosis when ChatGPT never exposes a new conversation URL.

    No editor text, cookies, or raw prompts are copied into the journal.
    """
    closed = getattr(page, "is_closed", lambda: False)()
    result = {"url": canonical(page.url),
              "page_closed": closed,
              "user_turn_contains_command": False if closed else verify_image_turn(page, command_id),
              "composer_contains_command": None,
              "composer_inspected": False}
    if closed:
        return result
    for selector in (
        "#prompt-textarea", "[data-testid='prompt-textarea']",
        "[contenteditable='true'][role='textbox']"
    ):
        try:
            node = page.locator(selector).first
            if not node.count() or not node.is_visible():
                continue
            try:
                content = node.input_value(timeout=2000)
            except Exception:
                content = node.text_content(timeout=2000) or ""
            result["composer_contains_command"] = command_id in content
            result["composer_inspected"] = True
            break
        except Exception as exc:
            result["composer_inspection_failed"] = True
            result["composer_error_type"] = type(exc).__name__
    return result


def browser_diagnostics(browser, starting_page):
    """Observe only route families and browser liveness, never chat contents.

    An empty list of /c/ URLs does not mean ChatGPT never received a turn:
    the browser may have closed or navigated to a route not recognized yet.
    """
    details = {"starting_page_closed": starting_page.is_closed(),
               "browser_connected": browser.is_connected(),
               "page_count": 0, "route_families": [],
               "cdp_target_count": None}
    try:
        routes = []
        for context in browser.contexts:
            for page in context.pages:
                details["page_count"] += 1
                url = canonical(page.url)
                if url.startswith("https://chatgpt.com/"):
                    path = url.split("chatgpt.com/", 1)[1]
                    if path.startswith("c/"):
                        routes.append("conversation")
                    elif path.startswith("g/"):
                        routes.append("gpt")
                    elif not path:
                        routes.append("home")
                    else:
                        routes.append("other_chatgpt_route")
                else:
                    routes.append("non_chatgpt")
        details["route_families"] = sorted(set(routes))
    except Exception as exc:
        details["page_listing_error_type"] = type(exc).__name__
    if browser.is_connected():
        try:
            session = browser.new_browser_cdp_session()
            try:
                details["cdp_target_count"] = len(
                    session.send("Target.getTargets").get("targetInfos", []))
            finally:
                session.detach()
        except Exception as exc:
            details["cdp_error_type"] = type(exc).__name__
    return details


def await_image_conversation(browser, starting_page, command_id, *,
                             seconds=150, baseline_urls=()):
    """Find and verify fresh ChatGPT conversation from all Chrome CDP targets."""
    baseline = set(baseline_urls)
    inspected = []
    probe = None
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        urls = image_conversation_urls(browser)
        # A new prompt can be submitted in a tab whose URL was already in
        # the CDP baseline (a reused /c/ route). Its unique USER command,
        # not just the URL's novelty, identifies the correct conversation.
        own_url = canonical(starting_page.url)
        if IMAGE_CHAT_RE.fullmatch(own_url) and own_url not in urls:
            urls.append(own_url)
        ordered = [url for url in urls
                   if url not in baseline or url == own_url]
        for url in ordered:
            pages = [p for context in browser.contexts
                     for p in context.pages if canonical(p.url) == url]
            if not pages:
                if probe is None:
                    probe = starting_page.context.new_page()
                try:
                    probe.goto(url, wait_until="domcontentloaded", timeout=15000)
                    pages = [probe]
                except Exception as exc:
                    inspected.append({"url": url, "error": type(exc).__name__})
                    continue
            for candidate in pages:
                if verify_image_turn(candidate, command_id):
                    return candidate, {"status": "verified", "url": url,
                                       "seen_urls": urls, "inspected": inspected[-10:]}
            inspected.append({"url": url, "status": "command_not_visible_yet"})
        time.sleep(1)
    return None, {"status": "not_found",
                  "seen_urls": image_conversation_urls(browser),
                  "inspected": inspected[-20:],
                  "starting_url": canonical(starting_page.url)}

