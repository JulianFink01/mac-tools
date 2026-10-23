import AppKit
@main struct CursorBoundaryChecks {
    static func main() {
        // A live event stream owns immediate exits. The position fallback only
        // takes over after delivery stops, even after a long time in the source.
        for tick in 1...36_000 {
            let now = Double(tick) / 30
            precondition(!PinnedCursorRecovery.shouldSample(now:now,lastMotion:now-0.008))
        }
        precondition(!PinnedCursorRecovery.shouldSample(now:21.05,lastMotion:21))
        precondition(PinnedCursorRecovery.shouldSample(now:21.15,lastMotion:21))
        precondition(PinnedCursorRecovery.shouldSample(now:3600,lastMotion:21))
        var gate = PinnedCursorEntryGate()
        for _ in 0..<10_000 {
            gate.returned(inside:false)
            precondition(!gate.admit(inside:false,explicit:false), "queued entry must not recapture a pointer outside the preview")
            precondition(gate.admit(inside:true,explicit:false), "real boundary re-entry must not wait for a timer")
        }
        gate.returned(inside:true)
        precondition(!gate.admit(inside:true,explicit:false), "Escape must not immediately re-enter")
        precondition(!gate.admit(inside:true,explicit:false), "motion after Escape must wait for a real exit")
        precondition(!gate.admit(inside:false,explicit:false))
        precondition(gate.admit(inside:true,explicit:false))
        gate.returned(inside:true)
        precondition(gate.admit(inside:true,explicit:true), "an explicit click must resume immediately after Escape")
        let source = CGRect(x: 1600, y: 60, width: 1200, height: 800)
        let view = CGRect(x: 0, y: 0, width: 600, height: 400)
        let edges: [(CGPoint, CGPoint)] = [
            (CGPoint(x:1600,y:400),CGPoint(x:-4,y:0)),
            (CGPoint(x:2799,y:400),CGPoint(x:4,y:0)),
            (CGPoint(x:2000,y:60),CGPoint(x:0,y:-4)),
            (CGPoint(x:2000,y:859),CGPoint(x:0,y:4))
        ]
        for (point, delta) in edges {
            let outside = PinnedCursorGeometry.exitPoint(at: point, delta: delta, frame: source)!
            let local = CGPoint(x:(outside.x-source.minX)/2,y:(outside.y-source.minY)/2)
            let returned = PinnedCursorGeometry.returnPoint(local,bounds:view,source:outside,frame:source)
            precondition(!source.contains(outside) && !view.contains(returned), "clamped display edge must allow escape")
            precondition(PinnedCursorGeometry.sourcePoint(returned,bounds:view,frame:source) == nil, "returned pointer must not immediately re-enter")
            let inside = CGPoint(x:min(view.maxX-0.5,max(view.minX+0.5,returned.x)),
                                 y:min(view.maxY-0.5,max(view.minY+0.5,returned.y)))
            precondition(PinnedCursorGeometry.sourcePoint(inside,bounds:view,frame:source) != nil, "a real re-entry one pixel inside must be immediately accepted")
            precondition(abs(returned.x-local.x) <= 1 && abs(returned.y-local.y) <= 1, "edge return must not jump ten points")
            precondition(PinnedCursorGeometry.exitPoint(at:point,delta:CGPoint(x:-delta.x,y:-delta.y),frame:source) == nil, "inward motion must stay native")
        }
        let center=CGPoint(x:2000,y:400)
        precondition(PinnedCursorGeometry.exitPoint(at:center,delta:CGPoint(x:200,y:100),frame:source) == nil)
        let letterbox = CGRect(x:0,y:0,width:600,height:600)
        precondition(PinnedCursorGeometry.sourcePoint(CGPoint(x:300,y:99.5),bounds:letterbox,frame:source) == nil)
        precondition(PinnedCursorGeometry.sourcePoint(CGPoint(x:300,y:100),bounds:letterbox,frame:source) == CGPoint(x:2200,y:60))
        // Queued physical-desktop positions must not override a current pointer
        // that already arrived safely on the private display.
        precondition(PinnedCursorGeometry.exitPoint(at:CGPoint(x:400,y:400),delta:.zero,frame:source) != nil)
        precondition(PinnedCursorGeometry.exitPoint(at:center,delta:.zero,frame:source) == nil)
        for x in stride(from:1602,through:2798,by:7) {
            for y in stride(from:62,through:858,by:7) {
                precondition(PinnedCursorGeometry.exitPoint(at:CGPoint(x:x,y:y),delta:CGPoint(x:1,y:1),frame:source) == nil)
            }
        }
        print("PASS: 10,000 immediate re-entry cycles, Escape/app-switch gate, explicit click, four edges, one-pixel return, letterboxing, stale-position check, and 19,000+ interior positions")
    }
}
