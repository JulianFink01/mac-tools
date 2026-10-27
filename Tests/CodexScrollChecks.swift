import AppKit

@main struct CodexScrollChecks {
    static func main() {
        var routing = CodexWheelRouting()
        func route(_ x: CGFloat = 0, _ y: CGFloat = 0, _ phase: NSEvent.Phase = [], _ momentum: NSEvent.Phase = [], web: Bool = true, modified: Bool = false, precise: Bool = true) -> CodexWheelRouting.Route {
            routing.route(x:x,y:y,precise:precise,phase:phase,momentum:momentum,overWeb:web,modified:modified)
        }
        precondition(route(0,0,.began) == .primeOuter)
        precondition(route(0,0.35,.changed) == .outer)
        precondition(!routing.needsHitTest(precise:true,phase:.changed,momentum:[]))
        precondition(route(0,1.75,.changed,web:false) == .outer, "Crossing inline message boundaries must not change the gesture owner")
        precondition(route(0,0,.ended,web:false) == .outer, "Zero-delta ending must reach AppKit")
        precondition(route(0,0,[],.began,web:false) == .outer, "Momentum begins after the touch gesture ends")
        precondition(route(0,0.125,[],.changed,web:false) == .outer)
        precondition(route(0,0,[],.ended,web:false) == .outer)
        precondition(!routing.isForwarding)
        print("PASS: complete precise gesture and momentum phases, zero-delta boundaries, stable owner across inline views and one hit-test per gesture")
        precondition(route(0,0,.began) == .primeOuter)
        precondition(route(3,0,.changed) == .native)
        precondition(route(2,0,.changed) == .native)
        precondition(route(0,0,.ended) == .primeOuter)
        precondition(route(0,0,[],.began) == .native)
        precondition(route(0,0,[],.ended) == .native)
        precondition(route(0,2,.began,modified:true) == .native)
        precondition(route(0,2,.changed,modified:true) == .native)
        precondition(route(0,0,.ended,modified:true) == .native)
        print("PASS: horizontal overflow and modified chart gestures retain native WebKit routing")
        precondition(route(0,2,.began) == .outer)
        precondition(route(0,0,.cancelled,web:false) == .outer && !routing.isForwarding)
        precondition(route(0,1,.began,web:false) == .native)
        precondition(route(0,1,.changed,web:true) == .native, "A gesture started in native content stays native")
        precondition(route(0,1,precise:false) == .outer)
        precondition(route(1,0,precise:false) == .native)
        precondition(route(0,1,web:false,precise:false) == .native)
        print("PASS: cancellation cleanup, native-origin gesture, ordinary mouse wheel and independent new gestures")
    }
}
