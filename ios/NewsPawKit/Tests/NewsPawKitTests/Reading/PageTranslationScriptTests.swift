import Foundation
@testable import NewsPawKit
import Testing
import WebKit

/// RD16 decisions 2, 3, 4, 6 and 8: the page script's static check, and
/// its behaviour in a real web view through the real bridge. Criteria 1,
/// 2, 4, 5, 6, 13, 14 and 16 (the package halves).
@Suite("Page translation script", .serialized)
@MainActor
struct PageTranslationScriptTests {
    // MARK: - Criterion 16: the static check

    /// What the script must never contain, as regular expressions on word
    /// boundaries (decision 2).
    static let forbidden: [String] = [
        #"\binnerHTML\b"#, #"\bouterHTML\b"#, #"\binsertAdjacent\w*"#, #"\bwrite(ln)?\s*\("#, #"\bcreateElement\b"#,
        #"\bcreateTextNode\b"#, #"\bcloneNode\b"#, #"\bappendChild\b"#, #"\binsertBefore\b"#, #"\breplaceChild\b"#,
        #"\bremoveChild\b"#, #"\breplaceChildren\b"#, #"\breplaceWith\b"#, #"\.\s*(remove|append|prepend|before|after)\s*\("#,
        #"\bsplitText\b"#, #"\.\s*normalize\s*\("#, #"\bexecCommand\b"#, #"\binsertNode\b"#, #"\bdeleteContents\b"#,
        #"\bextractContents\b"#, #"\bsurroundContents\b"#, #"\bsetAttribute\w*"#, #"\bremoveAttribute\w*"#, #"\btoggleAttribute\b"#,
        #"\battachShadow\b"#, #"\btextContent\b"#, #"\binnerText\b"#, #"\bouterText\b"#, #"\bnodeValue\b"#, #"\bcookie\b"#,
        #"\blocation\b"#, #"\bURL\b"#, #"\breferrer\b"#, #"\blocalStorage\b"#, #"\bsessionStorage\b"#, #"\bindexedDB\b"#,
        #"\bfetch\b"#, #"\bXMLHttpRequest\b"#, #"\bWebSocket\b"#, #"\bEventSource\b"#, #"\bWorker\b"#, #"\bImage\s*\("#,
        #"\bsendBeacon\b"#, #"\bpostMessage\b"#, #"\bmessageHandlers\b"#, #"\beval\b"#, #"\bFunction\s*\("#, #"\bimport\s*\("#,
        #"\.\s*(submit|click|open)\s*\("#, #"\.src\b"#, #"\.href\b"#,
        // The Swift interpolation of a raw string.
        ##"\\#\("##,
    ]

    /// The forbidden expressions `text` matches.
    static func violations(in text: String) throws -> [String] {
        // Simple word boundaries: the default Unicode ones see no boundary
        // in "el.innerHTML".
        try forbidden.filter { pattern in text.contains(try Regex(pattern).wordBoundaryKind(.simple)) }
    }

    @Test("criterion 16: the script contains none of the forbidden names, and is the same text the bridge sends")
    func staticCheck() throws {
        let source = PageTranslationScript.source
        let violations = try Self.violations(in: source)
        #expect(violations.isEmpty, "\(violations)")
        #expect(source.contains(#"const NAME = "\#(PageTranslationScript.stateName)";"#))
        // It writes `data` only, through the world's own setter.
        #expect(source.contains(#"describe(DATA, "data").set"#))
        #expect(PageScriptBridge.worldName != PageExtractor.contentWorld)
    }

    @Test("criterion 16: each forbidden name planted into a copy of the script is rejected")
    func plantedNames() throws {
        let plants = [
            "el.innerHTML = x;", "el.outerHTML = x;", "el.insertAdjacentHTML('beforeend', x);", "doc.write(x);", "doc.writeln(x);",
            "doc.createElement('b');", "doc.createTextNode(x);", "node.cloneNode(true);", "el.appendChild(node);",
            "el.insertBefore(a, b);", "el.replaceChild(a, b);", "el.removeChild(a);", "el.replaceChildren();", "el.replaceWith(a);",
            "el.remove();", "el.append(a);", "el.prepend(a);", "el.before(a);", "el.after(a);", "node.splitText(2);",
            "el.normalize();", "doc.execCommand('insertText');", "range.insertNode(a);", "range.deleteContents();",
            "range.extractContents();", "range.surroundContents(a);", "el.setAttribute('a', 'b');", "el.setAttributeNS(n, 'a', 'b');",
            "el.removeAttribute('a');", "el.toggleAttribute('a');", "el.attachShadow({mode: 'open'});", "x = el.textContent;",
            "x = el.innerText;", "x = el.outerText;", "x = node.nodeValue;", "x = doc.cookie;", "x = location;", "x = doc.URL;",
            "x = doc.referrer;", "localStorage.x = 1;", "sessionStorage.x = 1;", "indexedDB.open('x');", "fetch('/x');",
            "new XMLHttpRequest();", "new WebSocket('wss://x');", "new EventSource('/x');", "new Worker('w.js');", "new Image();",
            "navigator.sendBeacon('/x');", "parent.postMessage(x, '*');", "webkit.messageHandlers.x.postMessage(1);", "eval('1');",
            "Function('return 1')();", "import('/x.js');", "form.submit();", "link.click();", "window.open('/x');", "x = img.src;",
            "x = a.href;", #"const n = "\#\#(name)";"#,
        ]
        for plant in plants {
            let copy = PageTranslationScript.source.replacingOccurrences(of: "const LETTER", with: plant + "\nconst LETTER")
            #expect(!(try Self.violations(in: copy)).isEmpty, "\(plant)")
        }
        // What the script needs is not on the list.
        for allowed in [
            "parentOf.call(node)", "dataOf.call(node)", "setData.call(node, value)", "activeOf.call(doc)", "shadowOf.call(element)",
            "editableOf.call(element)", "pointOf.call(doc, 1, 2)", "new MutationObserver(() => {})",
            "listen.call(G, 'scroll', f)", "unlisten.call(G, 'scroll', f)", "state.records.delete(id)", "earlier.reverse()",
        ] {
            #expect(try Self.violations(in: allowed).isEmpty, "\(allowed)")
        }
    }

    // MARK: - Criterion 5: displayed text only

    static let sentinel = "fixture:never"

    /// Criterion 5's planted page: the sentinel in every place that is not
    /// displayed text, and visible foreign text beside it.
    static let plantedPage = """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Title fixture:never</title>
        <meta name="viewport" content="width=device-width">
        <style>.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)} body::after{content:"fixture:never"}</style>
        <script>document.cookie = "a=fixture:never"; var s = "fixture:never";</script>
        </head><body>
        <h1>表示されている見出し</h1>
        <p>表示されている本文です。</p>
        <input id="filled" value="x"><textarea id="area">fixture:never in a textarea</textarea>
        <select><option>fixture:never option</option><optgroup label="g"><option>fixture:never two</option></optgroup></select>
        <p style="display:none">fixture:never display none</p>
        <p style="visibility:hidden">fixture:never visibility hidden</p>
        <p style="opacity:0">fixture:never opacity zero</p>
        <p hidden>fixture:never hidden attribute</p>
        <details><summary>要約</summary><p>fixture:never in closed details</p></details>
        <div style="width:0;height:0;overflow:hidden">fixture:never zero size</div>
        <span class="sr">fixture:never visually hidden</span>
        <script>var t = "fixture:never in a script";</script>
        <noscript>fixture:never noscript</noscript>
        <img alt="fixture:never alt" title="fixture:never title" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
        <input placeholder="fixture:never placeholder"><button aria-label="fixture:never label">押す</button>
        <p translate="no">fixture:never translate no</p>
        <p class="notranslate">fixture:never notranslate</p>
        <pre>fixture:never pre</pre><p><code>fixture:never code</code></p>
        <iframe srcdoc="<p>fixture:never srcdoc</p>"></iframe>
        <iframe id="same"></iframe>
        <div id="host"></div>
        <div contenteditable="true">fixture:never contenteditable</div>
        <p style="position:absolute;left:-9999px">fixture:never far left</p>
        <div style="clip-path: inset(100%)">fixture:never clip-path inset</div>
        <div style="position:relative;overflow:hidden;height:40px"><p style="position:absolute;top:200px;margin:0">fixture:never outside its parent</p></div>
        <script>
        document.getElementById("filled").value = "fixture:never typed";
        document.getElementById("host").attachShadow({mode: "open"}).innerHTML = "<p>fixture:never shadow</p>";
        var frame = document.getElementById("same").contentDocument;
        frame.open(); frame.write("<p>fixture:never same origin frame</p>"); frame.close();
        </script>
        </body></html>
        """

    @Test("criterion 5: on the planted page the sentinel is in no collected run and in no request built from them; the visible text is collected")
    func plantedPage() async throws {
        let page = ScriptPage()
        await page.load(Self.plantedPage, address: try #require(URL(string: "http://127.0.0.1/planted?q=fixture:never")))
        try await page.settle()
        let runs = try await page.runs()
        #expect(runs.allSatisfy { !$0.text.contains(Self.sentinel) }, "\(runs.map(\.text))")
        let texts = Set(runs.map(\.text))
        #expect(texts.isSuperset(of: ["表示されている見出し", "表示されている本文です。", "要約", "押す"]), "\(texts)")
        let entries = PageBatcher.units(PageBatcher.groups(runs)).flatMap { $0.requests.flatMap { $0.map(\.text) } }
        #expect(!entries.isEmpty && entries.allSatisfy { !$0.contains(Self.sentinel) })
    }

    static let echoPage = """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head><body>
        <p>検索してください</p>
        <input id="q"><div id="echo"></div>
        <div id="host"></div><div id="shadowEcho"></div>
        <div id="closed"></div>
        <iframe id="frame" srcdoc="<input id='inner'>"></iframe>
        <button id="done">完了</button>
        <script>
        const q = document.getElementById("q");
        q.addEventListener("input", () => { document.getElementById("echo").textContent = "検索：" + q.value; });
        const root = document.getElementById("host").attachShadow({mode: "open"});
        root.innerHTML = "<input id='s'>";
        const s = root.getElementById("s");
        s.addEventListener("input", () => { document.getElementById("shadowEcho").textContent = "検索：" + s.value; });
        const closedRoot = document.getElementById("closed").attachShadow({mode: "closed"});
        closedRoot.innerHTML = "<input id='c'>";
        window.closedInput = closedRoot.getElementById("c");
        </script></body></html>
        """

    @Test("criterion 5: while a field has focus — plain, in an open shadow root, in a closed one, or in a frame — nothing is collected; after it leaves, the echo is displayed text")
    func focusedEcho() async throws {
        let page = ScriptPage()
        await page.load(Self.echoPage)
        try await page.page(#"const q = document.getElementById("q"); q.focus(); q.value = "fixture:never typed"; q.dispatchEvent(new Event("input"))"#)
        try await page.settle()
        #expect(try await page.pageString("return document.activeElement.id") == "q")
        #expect(try await page.collect().isHeld)
        // Inside an open shadow root.
        try await page.page(#"""
            const s = document.getElementById("host").shadowRoot.getElementById("s");
            s.focus(); s.value = "fixture:never shadow"; s.dispatchEvent(new Event("input"));
            """#)
        #expect(try await page.pageString("return document.activeElement.id") == "host")
        #expect(try await page.collect().isHeld)
        // Inside a closed shadow root: the host is reported.
        try await page.page("window.closedInput.focus()")
        #expect(try await page.pageString("return document.activeElement.id") == "closed")
        #expect(try await page.collect().isHeld)
        // Inside a frame.
        try await page.page(#"document.getElementById("frame").contentDocument.getElementById("inner").focus()"#)
        #expect(try await page.pageString("return document.activeElement.id") == "frame")
        #expect(try await page.collect().isHeld)
        // Focus leaves: what the page shows is displayed text.
        try await page.page(#"document.getElementById("done").focus()"#)
        #expect(try await page.pageString("return document.activeElement.id") == "done")
        let runs = try await page.runs()
        #expect(runs.contains { $0.text == "検索してください" })
        #expect(runs.contains { $0.text.hasPrefix("検索：") })
    }

    // MARK: - Criterion 4: the probe

    static let probePage = #"""
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><script>
        window.hits = {}; const mark = (name) => { hits[name] = (hits[name] || 0) + 1; };
        const data = Object.getOwnPropertyDescriptor(CharacterData.prototype, "data");
        Object.defineProperty(CharacterData.prototype, "data", {get() { mark("data.get"); return data.get.call(this); }, set(v) { mark("data.set"); data.set.call(this, v); }, configurable: true});
        Object.defineProperty(Node.prototype, "textContent", {get() { mark("textContent"); return ""; }, configurable: true});
        const NativeObserver = window.MutationObserver;
        window.MutationObserver = function (callback) { mark("MutationObserver"); return new NativeObserver(callback); };
        window.getComputedStyle = function () { mark("getComputedStyle"); return {getPropertyValue: () => "none"}; };
        Element.prototype.getBoundingClientRect = function () { mark("getBoundingClientRect"); return {width: 0, height: 0}; };
        Element.prototype.checkVisibility = function () { mark("checkVisibility"); return false; };
        Range.prototype.getClientRects = function () { mark("getClientRects"); return []; };
        Document.prototype.createTreeWalker = function () { mark("createTreeWalker"); return null; };
        Object.prototype.polluted = "P";
        window.events = [];
        for (const type of ["message", "newspaw", "translate", "translated"]) addEventListener(type, (e) => events.push(e.type), true);
        </script></head><body>
        <img name="readyState"><form name="documentElement"></form><form name="body"></form><img name="createTreeWalker">
        <img name="activeElement"><div id="__newsPawPageTranslation"></div>
        <p id="text">翻訳されるべき本文です。</p>
        <p translate="no" id="report"></p>
        <script>
        const before = Object.getOwnPropertyNames(window).sort().join(",");
        </script></body></html>
        """#

    @Test("criterion 4: the probe's overrides are never called, its clobbering names do not stop translation, and it finds no global, handler or event of the app's")
    func probe() async throws {
        let page = ScriptPage()
        await page.load(Self.probePage)
        let runs = try await page.runs()
        #expect(runs.map(\.text) == ["翻訳されるべき本文です。"])
        let applied = try await page.translateAll(runs)
        #expect(applied.written == runs.map(\.id))
        #expect(try await page.pageString(#"return data.get.call(document.getElementById("text").firstChild)"#) == "T:翻訳されるべき本文です。")
        try await page.settle()
        let report = try await page.pageString(#"""
            const after = Object.getOwnPropertyNames(window).sort().join(",");
            const state = window.__newsPawPageTranslation;
            const handlers = window.webkit && window.webkit.messageHandlers ? Object.keys(window.webkit.messageHandlers).length : 0;
            const isolated = after === before && state instanceof HTMLDivElement && handlers === 0 && events.length === 0 && Object.keys(hits).length === 0;
            const added = after.split(",").filter((name) => !before.split(",").includes(name)).join("|");
            return (isolated ? "isolated" : "reached") + " hits=" + JSON.stringify(hits) + " events=" + events.join("|") + " handlers=" + handlers
              + (added ? " added=" + added : "") + (state instanceof HTMLDivElement ? "" : " state=" + Object.prototype.toString.call(state));
            """#)
        #expect(report == "isolated hits={} events= handlers=0", "\(report)")
        #expect(try await page.end().restored == 1)
        #expect(try await page.pageString(#"return data.get.call(document.getElementById("text").firstChild)"#) == "翻訳されるべき本文です。")
        #expect(try await page.pageString("return Object.keys(hits).join(',')") == "")
    }

    // MARK: - Criteria 1 and 2: changes of text only, and exact restore

    static func listPage(items: Int = 12) -> String {
        let rows = (1...items).map { number in
            "<li><a href=\"/ja-item-\(number)\">項目 \(number) のタイトル</a> <img alt=\"画像\" width=\"40\" height=\"30\" src=\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\"></li>"
        }.joined()
        return """
            <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head><body>
            <h1>  日本語のリスト  </h1><p>前文と <a href="/more">リンク</a> と後文。</p><ul>\(rows)</ul>
            <p translate="no" id="report"></p>
            <script>
            window.counts = {childList: 0, attributes: 0, characterData: 0};
            new MutationObserver((records) => { for (const r of records) counts[r.type]++; })
              .observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
            </script></body></html>
            """
    }

    @Test("criteria 1 and 2: translating changes text only (no child-list or attribute mutation); Show Original restores the markup exactly, also with a failed run and after the page changed a translated run")
    func restore() async throws {
        let page = ScriptPage()
        await page.load(Self.listPage())
        let before = try await page.markup()
        let runs = try await page.runs()
        #expect(runs.count >= 10)
        // One run fails: settled, not written.
        let failed = runs[1]
        let written = runs.filter { $0.id != failed.id }
        let applied = try await page.apply(PageApplyRequest(
            writes: written.map { PageWrite(id: $0.id, text: "T:" + $0.text) }, settle: [failed.id]
        ))
        #expect(Set(applied.written) == Set(written.map(\.id)))
        try await page.settle()
        let counts = try await page.pageString("return JSON.stringify(counts)")
        #expect(counts == #"{"childList":0,"attributes":0,"characterData":\#(written.count)}"#)
        // Leading and trailing white space is kept around the translation.
        #expect(try await page.pageString("return document.querySelector('h1').firstChild.data") == " T:日本語のリスト ")
        // A settled run is not collected again; nothing new is found.
        #expect(try await page.runs().isEmpty)

        #expect(try await page.end().restored == written.count)
        #expect(try await page.markup() == before)

        // Again, with the page changing a translated run afterwards.
        let again = try await page.runs()
        _ = try await page.translateAll(again)
        try await page.page("document.querySelector('li a').firstChild.data = 'ページが変えた'")
        #expect(try await page.end().restored == again.count - 1)
        let expected = before.replacingOccurrences(of: "項目 1 のタイトル", with: "ページが変えた")
        #expect(try await page.markup() == expected)
        // After end the world holds nothing.
        #expect(try await page.end() == PageEnded(had: false, restored: 0))
    }

    @Test("criterion 6: a reply holding <b>, <script> and &lt; is written as literal text; no element appears")
    func markupAsText() async throws {
        let page = ScriptPage()
        await page.load(Self.listPage(items: 1))
        let elements = try await page.pageInt("return document.getElementsByTagName('*').length")
        let runs = try await page.runs()
        let reply = "<b>太字</b><script>window.ran = 1</script>&lt;"
        _ = try await page.apply(PageApplyRequest(writes: runs.map { PageWrite(id: $0.id, text: reply) }))
        try await page.settle()
        #expect(try await page.pageInt("return document.getElementsByTagName('*').length") == elements)
        #expect(try await page.pageInt("return document.getElementsByTagName('b').length") == 0)
        #expect(try await page.pageString("return String(window.ran)") == "undefined")
        #expect(try await page.pageString("return document.querySelector('li a').firstChild.data") == reply)
    }

    // MARK: - Criterion 14: the write guard

    @Test("criterion 14: a run whose node changed between collect and apply, or that the page moved under script, style or textarea, is not written")
    func guardOnWrite() async throws {
        let page = ScriptPage()
        await page.load("""
            <!doctype html><html lang="ja"><body><p id="a">一つ目の文</p><p id="b">二つ目の文</p><p id="c">三つ目の文</p>
            <p id="d">四つ目の文</p><p id="e">五つ目の文</p>
            <script id="s" type="text/x-later"></script><style id="st"></style><textarea id="ta"></textarea></body></html>
            """)
        let runs = try await page.runs()
        let byText = Dictionary(uniqueKeysWithValues: runs.map { ($0.text, $0.id) })
        try await page.page(#"""
            document.getElementById("a").firstChild.data = "ページが変えた";
            document.getElementById("s").appendChild(document.getElementById("b").firstChild);
            document.getElementById("st").appendChild(document.getElementById("c").firstChild);
            document.getElementById("ta").appendChild(document.getElementById("d").firstChild);
            """#)
        let applied = try await page.translateAll(runs)
        #expect(applied.written == [byText["五つ目の文"]].compactMap { $0 })
        #expect(Set(applied.skipped) == Set(["一つ目の文", "二つ目の文", "三つ目の文", "四つ目の文"].compactMap { byText[$0] }))
        #expect(try await page.pageString(#"return document.getElementById("s").firstChild.data"#) == "二つ目の文")
        // `check` reports only the runs that still hold their original.
        let fresh = try await page.runs()
        let checked = try await page.apply(PageApplyRequest(check: fresh.map(\.id) + [999_999]))
        #expect(checked.holding == fresh.map(\.id))
    }

    // MARK: - Whole runs and blocks

    @Test("whole: a single list item and a link alone in its item are whole; a link inside a paragraph and '3 comments' are not")
    func wholeRuns() async throws {
        let page = ScriptPage()
        await page.load("""
            <!doctype html><html lang="en"><body>
            <ul><li>Single item</li><li><a href="/x">Linked item</a></li></ul>
            <p>Read the <a href="/r">full report</a> before Friday.</p>
            <div><span>3</span> comments</div>
            </body></html>
            """)
        let runs = try await page.runs()
        func run(_ text: String) -> PageRun? { runs.first { $0.text == text } }
        #expect(run("Single item")?.whole == true)
        #expect(run("Linked item")?.whole == true)
        #expect(run("Read the")?.whole == false)
        #expect(run("full report")?.whole == false)
        #expect(run("comments")?.whole == false)
        // The paragraph's runs share one block, in order.
        let paragraph = runs.filter { ["Read the", "full report", "before Friday."].contains($0.text) }
        #expect(paragraph.count == 3 && Set(paragraph.map(\.block)).count == 1)
        #expect(PageBatcher.groups(runs).first { $0.block == paragraph[0].block }?.texts == ["Read the", "full report", "before Friday."])
    }

    // MARK: - The band, the flag and the walk (decision 4; criterion 13)

    @Test("the band: an item three screens below is not collected until the page scrolls to it; nothing changed answers unchanged")
    func band() async throws {
        let page = ScriptPage()
        let filler = (1...40).map { "<p>段落 \($0) の文章です。</p>" }.joined()
        await page.load("""
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width">
            <style>p{height:60px;margin:0}</style></head><body>\(filler)
            <div style="height:2100px"></div><p id="far">三画面下の項目</p><div style="height:1000px"></div></body></html>
            """)
        let first = try await page.runs()
        #expect(!first.isEmpty && !first.contains { $0.text == "三画面下の項目" })
        #expect(first.first?.inView == true)
        // Visible runs come first.
        let firstOutside = first.firstIndex { !$0.inView } ?? first.count
        #expect(first[firstOutside...].allSatisfy { !$0.inView })
        #expect(first[..<firstOutside].allSatisfy { $0.inView })
        #expect(try await page.collect().isUnchanged)
        try await page.page(#"document.getElementById("far").scrollIntoView()"#)
        try await page.settle()
        let after = try await page.runs()
        #expect(after.contains { $0.text == "三画面下の項目" && $0.inView })
    }

    @Test("criterion 13: a tab panel shown by a class change, and text an inner element scrolls into view, set the flag and are collected")
    func dirtyFlag() async throws {
        let page = ScriptPage()
        let inner = (1...30).map { "<p style=\"height:50px;margin:0\">内側 \($0) の文</p>" }.joined()
        await page.load("""
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width">
            <style>.tab{display:none}.tab.on{display:block} body{margin:0;height:700px;overflow:hidden}</style></head><body>
            <div id="one" class="tab on">一つ目のタブ</div><div id="two" class="tab">二つ目のタブ</div>
            <div id="box" style="height:300px;overflow:auto">\(inner)<p id="deep" style="margin:0">箱の奥の文</p>
            <div style="height:2000px"></div><p id="deeper" style="margin:0">箱のさらに奥の文</p></div>
            </body></html>
            """)
        let first = try await page.runs()
        #expect(first.contains { $0.text == "一つ目のタブ" } && !first.contains { $0.text == "二つ目のタブ" })
        #expect(!first.contains { $0.text == "箱のさらに奥の文" })
        _ = try await page.translateAll(first)
        #expect(try await page.runs().isEmpty)
        #expect(try await page.collect().isUnchanged)
        try await page.page(#"document.getElementById("one").className = "tab"; document.getElementById("two").className = "tab on""#)
        try await page.settle()
        #expect(try await page.runs().map(\.text) == ["二つ目のタブ"])
        #expect(try await page.collect().isUnchanged)
        // The window does not scroll; the box does.
        // Into the box's own view: text the box clips is not displayed.
        try await page.page(#"const box = document.getElementById("box"); box.scrollTop = box.scrollHeight"#)
        try await page.settle()
        #expect(try await page.runs().contains { $0.text == "箱のさらに奥の文" })
    }

    @Test("R4: an apply naming another script state writes, settles and reports nothing; the state's own token works")
    func foreignState() async throws {
        let page = ScriptPage()
        await page.load("<!doctype html><html lang='ja'><body><p>一つ目の文</p><p>二つ目の文</p></body></html>")
        let runs = try await page.runs()
        let token = try #require(page.token)
        #expect(!token.isEmpty)
        let foreign = try await page.apply(PageApplyRequest(writes: runs.map { PageWrite(id: $0.id, text: "x") }, check: runs.map(\.id), state: "another"))
        #expect(foreign.foreign && foreign.written.isEmpty && foreign.holding.isEmpty)
        #expect(try await page.pageString("return document.querySelector('p').firstChild.data") == "一つ目の文")
        // A state ended and made again has another token.
        _ = try await page.end()
        _ = try await page.collect()
        #expect(page.token != token)
        let stale = try await page.apply(PageApplyRequest(writes: runs.map { PageWrite(id: $0.id, text: "x") }, state: token))
        #expect(stale.foreign && stale.written.isEmpty)
        let own = try await page.apply(PageApplyRequest(writes: runs.map { PageWrite(id: $0.id, text: "訳") }))
        #expect(own.written.count == 2 && !own.foreign)
    }

    @Test("G6: a block that starts above the viewport and goes on into it comes first, its runs in document order")
    func blockOrder() async throws {
        let page = ScriptPage()
        let filler = (1...30).map { "<p style=\"margin:0;height:40px\">前の段落 \($0)</p>" }.joined()
        await page.load("""
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width">
            <style>body{margin:0} #p{margin:0;line-height:40px}</style></head><body>\(filler)
            <p id="p">段落の始まり<a href="/x">リンク</a>\(String(repeating: "<br>", count: 12))段落の終わり</p>
            <div style="height:3000px"></div></body></html>
            """)
        // The paragraph's first line just above the viewport, its end in it.
        try await page.page(#"window.scrollTo(0, document.getElementById("p").offsetTop + 80)"#)
        try await page.settle()
        let runs = try await page.runs()
        let paragraph = runs.filter { ["段落の始まり", "リンク", "段落の終わり"].contains($0.text) }
        #expect(paragraph.map(\.text) == ["段落の始まり", "リンク", "段落の終わり"], "\(runs.map(\.text))")
        #expect(paragraph.contains { $0.inView } && paragraph.contains { !$0.inView })
        // The block is in view: it comes before the blocks that are only
        // in the band.
        let firstOther = runs.firstIndex { $0.text.hasPrefix("前の段落") } ?? runs.count
        let lastOfBlock = runs.lastIndex { paragraph.map(\.id).contains($0.id) } ?? 0
        #expect(lastOfBlock < firstOther)
        #expect(PageBatcher.groups(runs).first?.texts == ["段落の始まり", "リンク", "段落の終わり"])
    }

    @Test("M1: text that an ancestor clips away is not displayed; text in view inside a clipping box and a fixed header still are; an inner box's text is collected once scrolled into its view")
    func clippedText() async throws {
        let page = ScriptPage()
        await page.load("""
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width">
            <style>body{margin:0} .box{width:300px;height:60px;margin:4px 0} p{margin:0}</style></head><body>
            <div class="box" style="clip-path: inset(100%)">切り抜き百パーセント</div>
            <div class="box" style="clip-path: inset(50%)">切り抜き五十パーセント</div>
            <div class="box" style="clip-path: inset(10px 20px 50px 0px)">上下で消える切り抜き</div>
            <div class="box" style="clip-path: circle(0)">半径ゼロの円</div>
            <div class="box" style="clip-path: ellipse(0px 10px)">幅ゼロの楕円</div>
            <div class="box" style="clip-path: polygon(0 0, 100% 0, 0 100%)">多角形の切り抜き</div>
            <div class="box" style="clip-path: inset(10%)">少しだけの切り抜き</div>
            <div class="box" style="position:relative;overflow:hidden"><p style="position:absolute;top:200px">箱の外の文</p><p>箱の中の文</p></div>
            <div class="box" style="position:relative;overflow:clip"><p style="position:absolute;left:310px;white-space:nowrap">右にはみ出た文</p></div>
            <div class="box" style="position:relative;contain:paint"><p style="position:absolute;top:-100px">上にはみ出た文</p></div>
            <p style="position:absolute;width:300px;height:20px;clip:rect(0 0 0 0)">古い切り抜き</p>
            <div style="overflow:hidden;height:10px;margin-top:20px"><div style="position:fixed;top:0;left:0">固定されたヘッダー</div></div>
            <div id="inner" class="box" style="overflow:auto"><p>内側の箱の最初の文</p><div style="height:300px"></div><p>内側の箱の奥の文</p></div>
            </body></html>
            """)
        let texts = Set(try await page.runs().map(\.text))
        for hidden in ["切り抜き百パーセント", "切り抜き五十パーセント", "上下で消える切り抜き", "半径ゼロの円", "幅ゼロの楕円", "箱の外の文",
                       "右にはみ出た文", "上にはみ出た文", "古い切り抜き", "内側の箱の奥の文"] {
            #expect(!texts.contains(hidden), "\(hidden)")
        }
        for shown in ["多角形の切り抜き", "少しだけの切り抜き", "箱の中の文", "固定されたヘッダー", "内側の箱の最初の文"] {
            #expect(texts.contains(shown), "\(shown)")
        }
        try await page.page(#"document.getElementById("inner").scrollTop = 300"#)
        // The box's scroll event is delivered with a later frame; collect
        // until it has been (bounded), as the session's ticks do.
        var seen: [String] = []
        for _ in 0..<40 where !seen.contains("内側の箱の奥の文") {
            try await page.settle()
            let collection = try await page.collect()
            if case .runs(let runs, _, _, _) = collection { seen = runs.map(\.text) } else { seen = ["\(collection)"] }
        }
        let scrollTop = try await page.page(#"return document.getElementById("inner").scrollTop"#)
        #expect(seen.contains("内側の箱の奥の文"), "\(seen); scrollTop \(String(describing: scrollTop))")
    }

    @Test("a run of more than 20,000 UTF-16 code units is never returned")
    func longRun() async throws {
        let page = ScriptPage()
        let long = String(repeating: "あ", count: 20_001)
        await page.load("<!doctype html><html><body><p>短い文</p><p>\(long)</p></body></html>")
        let runs = try await page.runs()
        #expect(runs.map(\.text) == ["短い文"])
    }

    /// A long list page with a fixed header and a page script that changes
    /// an attribute every 16 ms, so that the flag stays set.
    static func longPage(items: Int, animated: Bool) -> String {
        let rows = (1...items).map { "<li>項目 \($0)</li>" }.joined()
        let animation = animated
            ? "<script>let n = 0; setInterval(() => { document.body.dataset.n = String(n++); }, 16);</script>" : ""
        return """
            <!doctype html><html lang="ja"><head><meta name="viewport" content="width=device-width">
            <style>header{position:fixed;top:0;left:0;right:0;height:50px;background:#eee} li{height:20px}</style></head><body>
            <header>固定ヘッダー</header><ul>\(rows)</ul>\(animation)</body></html>
            """
    }

    @Test("A8: the walk starts at the viewport's centre on a very long page with a fixed header, and stops 300 nodes outside the band with the flag kept set; timings recorded")
    func longPageWalk() async throws {
        let page = ScriptPage()
        await page.load(Self.longPage(items: 10_000, animated: false))
        let clock = ContinuousClock()
        var first: [PageRun] = []
        let full = try await clock.measure { first = try await page.runs() }
        #expect(first.contains { $0.text == "固定ヘッダー" })
        #expect(first.count < 200, "the band of the top of the page only: \(first.count)")
        let unchanged = try await clock.measure { _ = try await page.collect() }
        // The middle of the page.
        try await page.page("window.scrollTo(0, 100000)")
        try await page.settle()
        var middle: [PageRun] = []
        let moved = try await clock.measure { middle = try await page.runs() }
        let numbers = middle.compactMap { Int($0.text.replacingOccurrences(of: "項目 ", with: "")) }
        #expect(numbers.contains(5_000 + 10) || numbers.contains { (4_990...5_100).contains($0) }, "\(numbers.prefix(5))")
        #expect(middle.first?.inView == true)

        let animated = ScriptPage()
        await animated.load(Self.longPage(items: 10_000, animated: true))
        try await animated.page("window.scrollTo(0, 100000)")
        try await animated.settle()
        _ = try await animated.runs()
        var flagged: Duration = .zero
        for _ in 0..<3 {
            try await animated.settle()
            flagged = max(flagged, try await clock.measure { _ = try await animated.collect() })
        }
        let line = "A8 \(Self.platform): first collection \(full), unchanged \(unchanged), middle \(moved), flag kept set (worst of 3) \(flagged)"
        print(line)
        Self.record(line)
        // Wide bounds: the design's are 200 ms, 50 ms and 5 ms on the
        // iPhone simulator; the numbers are recorded, not asserted.
        #expect(full < .seconds(5) && moved < .seconds(5) && flagged < .seconds(5))
    }

    @Test("the walk from the viewport's centre reaches the viewport on a page of 120,000 nodes")
    func hugePage() async throws {
        let page = ScriptPage()
        await page.load(Self.longPage(items: 60_000, animated: false))
        try await page.page("window.scrollTo(0, document.body.scrollHeight / 2)")
        try await page.settle()
        let runs = try await page.runs()
        let numbers = runs.compactMap { Int($0.text.replacingOccurrences(of: "項目 ", with: "")) }
        #expect(numbers.contains { (29_000...31_500).contains($0) }, "\(numbers.prefix(5))")
    }

    static var platform: String {
        #if os(iOS)
        "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }

    /// Appends a measurement to the run's record file, when one is named.
    static func record(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["RD16_RECORD"] else { return }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - World state (A1)

    @Test("A1: the bridge keeps its world, and the state lives between calls in one document and is gone in the next")
    func worldState() async throws {
        let page = ScriptPage()
        #expect(page.bridge.world === WKContentWorld.world(name: PageScriptBridge.worldName))
        await page.load("<!doctype html><html lang='ja'><body><p>一つ目の文書</p></body></html>")
        let runs = try await page.runs()
        #expect(runs.count == 1)
        #expect(try await page.collect().isUnchanged)
        await page.load("<!doctype html><html lang='ja'><body><p>二つ目の文書</p></body></html>")
        #expect(try await page.apply(PageApplyRequest(writes: [PageWrite(id: runs[0].id, text: "x")])).skipped == [runs[0].id])
        #expect(try await page.end() == PageEnded(had: false, restored: 0))
        #expect(try await page.runs().map(\.text) == ["二つ目の文書"])
    }
}
