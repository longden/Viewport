import CoreGraphics
import Foundation
import WebKit

/// Collects labelled and interactive elements from the web pane's viewport.
enum WebElementSnapshot {
    struct Payload: Decodable, Equatable {
        let viewportWidth: Double
        let viewportHeight: Double
        let elements: [Element]

        struct Element: Decodable, Equatable {
            let role: String
            let tag: String
            let label: String?
            let text: String?
            let identifier: String?
            let value: String?
            let x: Double
            let y: Double
            let width: Double
            let height: Double
            let interactive: Bool
            let enabled: Bool
            let depth: Int
        }
    }

    @MainActor
    static func capture(in webView: WKWebView) async throws -> ElementSnapshot {
        let raw = try await webView.evaluateJavaScript(script)
        guard let json = raw as? String else {
            throw ElementSnapshotError.failed("The web page didn’t return its elements.")
        }
        return try parse(json)
    }

    /// Token that changes when the page's DOM changes, scrolls, or resizes, so
    /// hover only re-walks the DOM when the last snapshot is out of date.
    @MainActor
    static func contentVersion(in webView: WKWebView) async -> String? {
        (try? await webView.evaluateJavaScript(contentVersionScript)) as? String
    }

    static let contentVersionScript = """
    (() => {
      if (window.__viewportInspectVersion === undefined) {
        window.__viewportInspectDocument = Math.random().toString(36).slice(2);
        window.__viewportInspectVersion = 1;
        const bump = () => { window.__viewportInspectVersion++; };
        new MutationObserver(bump).observe(document.documentElement,
          { subtree: true, childList: true, attributes: true, characterData: true });
        addEventListener("scroll", bump, { capture: true, passive: true });
        addEventListener("resize", bump);
      }
      return window.__viewportInspectDocument + ":" + window.__viewportInspectVersion;
    })();
    """

    static func parse(_ json: String, capturedAt: Date = Date()) throws -> ElementSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        let width = max(payload.viewportWidth, 1)
        let height = max(payload.viewportHeight, 1)
        let elements = payload.elements.enumerated().map { index, element in
            let role = role(for: element.role)
            return InspectedElement(
                id: index,
                role: role,
                platformRole: element.role == "generic" ? element.tag : "\(element.tag) [\(element.role)]",
                label: nonEmpty(element.label),
                text: nonEmpty(element.text).flatMap { $0 == element.label ? nil : $0 },
                identifier: nonEmpty(element.identifier),
                value: nonEmpty(element.value),
                frame: CGRect(
                    x: element.x / width,
                    y: element.y / height,
                    width: element.width / width,
                    height: element.height / height
                ),
                size: CGSize(width: element.width, height: element.height),
                isInteractive: element.interactive || role.isInteractive,
                isEnabled: element.enabled,
                depth: element.depth
            )
        }
        return ElementSnapshot(
            source: .web,
            elements: elements,
            screenSize: CGSize(width: width, height: height),
            unit: "px",
            capturedAt: capturedAt
        )
    }

    static func role(for ariaRole: String) -> ElementRole {
        switch ariaRole.lowercased() {
        case "button", "menuitem", "menuitemcheckbox", "menuitemradio": .button
        case "link": .link
        case "textbox", "searchbox", "spinbutton": .textField
        case "checkbox", "radio", "switch": .toggle
        case "slider": .slider
        case "img", "image", "figure": .image
        case "heading": .heading
        case "tab": .tab
        case "combobox", "listbox", "option": .picker
        case "cell", "gridcell", "row", "listitem", "columnheader", "rowheader": .cell
        case "text", "paragraph", "statictext": .text
        case "generic", "group", "region", "list", "navigation", "main", "banner": .container
        default: .other
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let script = """
    (() => {
      const vw = window.innerWidth || document.documentElement.clientWidth;
      const vh = window.innerHeight || document.documentElement.clientHeight;
      const maxWalk = 6000, maxOut = 1500;
      const interactiveRoles = new Set(["button","link","checkbox","radio","switch","tab","menuitem",
        "menuitemcheckbox","menuitemradio","option","textbox","searchbox","combobox","slider","spinbutton"]);
      const contentNameRoles = new Set(["button","link","heading","tab","menuitem","option","cell",
        "gridcell","columnheader","rowheader","checkbox","radio","switch"]);
      const clean = (s) => (s || "").replace(/\\s+/g, " ").trim().slice(0, 240);
      const roleOf = (el) => {
        const explicit = (el.getAttribute("role") || "").trim().split(/\\s+/)[0];
        if (explicit) return explicit.toLowerCase();
        const tag = el.tagName.toLowerCase();
        switch (tag) {
          case "a": return el.hasAttribute("href") ? "link" : "generic";
          case "button": case "summary": return "button";
          case "input": {
            const t = (el.getAttribute("type") || "text").toLowerCase();
            if (["button","submit","reset","image"].includes(t)) return "button";
            if (t === "checkbox") return "checkbox";
            if (t === "radio") return "radio";
            if (t === "range") return "slider";
            if (t === "hidden") return "hidden";
            if (t === "search") return "searchbox";
            return "textbox";
          }
          case "textarea": return "textbox";
          case "select": return "combobox";
          case "img": case "svg": case "picture": case "canvas": return "img";
          case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
          case "li": return "listitem";
          case "td": return "cell";
          case "th": return "columnheader";
          case "p": return "paragraph";
          default: return "generic";
        }
      };
      const accessibleName = (el, role) => {
        const labelledby = el.getAttribute("aria-labelledby");
        if (labelledby) {
          const text = labelledby.split(/\\s+/).map((id) => document.getElementById(id))
            .filter(Boolean).map((n) => n.innerText || n.textContent || "").join(" ");
          if (clean(text)) return clean(text);
        }
        const aria = el.getAttribute("aria-label");
        if (clean(aria)) return clean(aria);
        const tag = el.tagName.toLowerCase();
        if (tag === "img" || (tag === "input" && (el.type || "") === "image")) {
          const alt = el.getAttribute("alt");
          if (alt !== null) return clean(alt);
        }
        if (tag === "svg") {
          const title = el.querySelector("title");
          if (title) return clean(title.textContent);
        }
        if (tag === "input" || tag === "textarea" || tag === "select") {
          if (el.labels && el.labels.length) {
            const text = Array.from(el.labels).map((l) => l.innerText || "").join(" ");
            if (clean(text)) return clean(text);
          }
          if (["submit","button","reset"].includes((el.type || "").toLowerCase())) return clean(el.value);
        }
        if (contentNameRoles.has(role)) {
          const text = clean(el.innerText);
          if (text) return text;
        }
        const title = el.getAttribute("title");
        if (clean(title)) return clean(title);
        if (tag === "input" || tag === "textarea") return clean(el.getAttribute("placeholder"));
        return "";
      };
      const ownText = (el) => {
        let text = "";
        for (const node of el.childNodes) {
          if (node.nodeType === 3) text += node.textContent;
        }
        return clean(text);
      };
      const out = [];
      let walked = 0;
      const visit = (el, depth) => {
        if (walked++ > maxWalk || out.length >= maxOut) return;
        if (el.getAttribute("aria-hidden") === "true") return;
        const tag = el.tagName.toLowerCase();
        if (["script","style","noscript","template","head","meta","link"].includes(tag)) return;
        const style = getComputedStyle(el);
        if (style.display === "none") return;
        const visible = style.visibility !== "hidden" && parseFloat(style.opacity || "1") > 0.01;
        const rect = el.getBoundingClientRect();
        const onScreen = rect.width >= 1 && rect.height >= 1 && rect.bottom > 0 && rect.right > 0
          && rect.top < vh && rect.left < vw;
        if (visible && onScreen) {
          const role = roleOf(el);
          if (role !== "hidden" && role !== "presentation" && role !== "none") {
            const parentPointer = el.parentElement && getComputedStyle(el.parentElement).cursor === "pointer";
            const tabbable = el.hasAttribute("tabindex") && el.tabIndex >= 0;
            const interactive = interactiveRoles.has(role) || tabbable
              || (style.cursor === "pointer" && !parentPointer && role === "generic" && clean(el.innerText).length > 0);
            const label = accessibleName(el, role);
            const text = ownText(el);
            const include = interactive || role === "img" || role === "heading"
              || el.hasAttribute("aria-label") || text.length > 0;
            if (include) {
              const disabled = el.disabled === true || el.getAttribute("aria-disabled") === "true";
              const id = el.id || el.getAttribute("data-testid") || el.getAttribute("data-test-id")
                || el.getAttribute("data-test") || el.getAttribute("name") || "";
              let value = null;
              if (tag === "input" && ["checkbox","radio"].includes((el.type || "").toLowerCase())) {
                value = el.checked ? "On" : "Off";
              } else if (tag === "input" || tag === "textarea" || tag === "select") {
                value = clean(el.value) || null;
              }
              out.push({
                role: interactive && role === "generic" ? "button" : role,
                tag, label: label || null, text: text || null, identifier: id || null, value,
                x: rect.left, y: rect.top, width: rect.width, height: rect.height,
                interactive, enabled: !disabled, depth
              });
            }
          }
        }
        for (const child of el.children) visit(child, depth + 1);
      };
      if (document.body) visit(document.body, 0);
      return JSON.stringify({ viewportWidth: vw, viewportHeight: vh, elements: out });
    })();
    """
}
