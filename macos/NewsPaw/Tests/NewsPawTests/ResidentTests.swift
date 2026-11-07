import ServiceManagement
import Testing
@testable import NewsPaw

@Test func packagedLoginStatusIsNotInferredFromSocketConnectivity() {
    #expect(ResidentState.status(.notRegistered) == .off)
    #expect(ResidentState.status(.requiresApproval) == .approval)
    #expect(ResidentState.status(.enabled) == .on)
    #expect(ResidentState.status(.notFound) == .unavailable)
    #expect(ResidentAgent().state == .notPackaged)
}
