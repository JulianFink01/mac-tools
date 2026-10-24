import AppKit
import SwiftUI

/// Exercise production transient focus, dismissal and fixed hosting geometry.
@MainActor final class PopoverLayoutFixture {
 let popover = NSPopover()
 let positioning: PinnedChatPopoverAnchor
 let item: NSStatusItem
 let store: CodexStore
 init(item: NSStatusItem, store: CodexStore) {
  self.item=item;self.store=store;positioning=PinnedChatPopoverAnchor(popover:popover)
  popover.behavior = .transient;popover.contentSize=NSSize(width:560,height:680)
  popover.contentViewController=CodexPinnedChatMenu.contentController(store:store,size:popover.contentSize)
  store.prepareSelection("test-old");store.start()
  Task{await store.connect();await store.finishSelection("test-old")}
 }
 func toggle(){if popover.isShown{positioning.close()}else if let button=item.button{store.presentationRevision+=1;positioning.show(from:button,at:NSEvent.mouseLocation)}}
 func stop(){positioning.close();store.stop()}
 var diagnostics:[String:Any]{["popoverShown":popover.isShown,"messageCount":store.messages.count,"preferredSize":NSStringFromSize(popover.contentViewController!.preferredContentSize)].merging(positioning.diagnostics){_,new in new}}
}
@MainActor final class PopoverLayoutChecks:NSObject,NSApplicationDelegate,ObservableObject {
 let detailPopover=NSPopover();var window:NSWindow!;var stores:[CodexStore]=[];var connections:[CodexConnection]=[];var items:[NSStatusItem]=[];var menus:[PopoverLayoutFixture]=[];var timer:Timer?;var stress:Task<Void,Never>?;var updates=0;var samples=0;var splitViews=0;var sizes=Set<String>()
 func applicationDidFinishLaunching(_ n:Notification){
  setenv("MACTOOLS_QA_LONG_HISTORY","1",1)
  for i in 0..<2 {
   let domain="MacTools.PopoverLayoutChecks.\(i)",prefs=UserDefaults(suiteName:domain)!;prefs.removePersistentDomain(forName:domain);prefs.set(["test-old"],forKey:"macToolsCodexThreads")
   let connection=CodexConnection(executableURL:Bundle.main.url(forResource:"codex-app-server",withExtension:"py")!)
   let store=CodexStore(connection:connection,defaults:prefs,followAllChats:false,queue:CodexQueueRepository(defaults:prefs))
   connections.append(connection);stores.append(store)
   let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength);items.append(item);menus.append(PopoverLayoutFixture(item:item,store:store))
  }
  detailPopover.behavior = .transient;detailPopover.contentSize=NSSize(width:360,height:240)
  detailPopover.contentViewController=NSHostingController(rootView:VStack{Text("Monitor · isolierter Popup-Fokustest");Button("Schließen"){self.detailPopover.close()}}.frame(width:360,height:240))
  window=NSWindow(contentRect:NSRect(x:100,y:100,width:500,height:220),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="Chat-Popup · isolierter Absturztest";window.isReleasedWhenClosed=false
  window.contentView=NSHostingView(rootView:VStack(spacing:20){Text("Echte Menüleisten-Popovers mit Testdaten").font(.headline);Button("Popup 1 öffnen und Stream testen"){self.open(0)};Button("Popup 2 öffnen und Stream testen"){self.open(1)};Button("Popup nach 3 Sekunden öffnen"){Task{try? await Task.sleep(nanoseconds:3_000_000_000);self.open(0)}};Button("Monitor-Popup öffnen"){if let button=self.items[1].button{self.detailPopover.showFocused(relativeTo:button.bounds,of:button,preferredEdge:.minY)}}}.frame(maxWidth:.infinity,maxHeight:.infinity));window.makeKeyAndOrderFront(nil)
  let menu=NSMenu();let item=NSMenuItem();let sub=NSMenu();item.submenu=sub;sub.addItem(withTitle:"Beenden",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");menu.addItem(item);NSApp.mainMenu=menu
  timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){[weak self]_ in Task{@MainActor in self?.record()}}
 }
 func open(_ index:Int){menus[index].toggle();
  stress?.cancel();stress=Task{
  for i in 0..<160 {
   if Task.isCancelled{return}
   _ = try? await connections[index].request("test/ui-command-update")
   stores[index].error = i % 4 == 0 ? "Temporärer Testhinweis · verändert die verfügbare Scrollhöhe." : nil
   if i % 32 == 8 {_ = try? await connections[index].request("test/async-question",["idle":true]);await stores[index].select("test-old")}
   if i % 32 == 24,let q=stores[index].asyncQuestions.first {_ = await stores[index].answerAsync(q,answer:"Details")}
   updates += 1
   try? await Task.sleep(nanoseconds:30_000_000)
  }
 }}
 func record(){
  func count(_ v:NSView)->Int{(v is NSSplitView ? 1:0)+v.subviews.reduce(0){$0+count($1)}}
  for w in NSApp.windows where NSStringFromClass(type(of:w)).contains("Popover") && w.isVisible {samples+=1;if let v=w.contentView {splitViews=max(splitViews,count(v));sizes.insert(NSStringFromSize(v.bounds.size))}}
  let state:[String:Any] = ["appActive":NSApp.isActive,"detailShown":detailPopover.isShown,"detailKey":detailPopover.contentViewController?.view.window?.isKeyWindow ?? false,"updates":updates,"samples":samples,"maxSplitViews":splitViews,"sizes":sizes.sorted(),"popovers":menus.map(\.diagnostics)]
  if let data=try? JSONSerialization.data(withJSONObject:state,options:.sortedKeys){try? data.write(to:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("popover-layout-checks.json"))}
 }
 func applicationWillTerminate(_ n:Notification){stress?.cancel();timer?.invalidate();detailPopover.close();menus.forEach{$0.stop()};items.forEach{NSStatusBar.system.removeStatusItem($0)}}
}
@main struct PopoverLayoutChecksApp{static func main(){let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=PopoverLayoutChecks();app.delegate=delegate;app.run();withExtendedLifetime(delegate){}}}
