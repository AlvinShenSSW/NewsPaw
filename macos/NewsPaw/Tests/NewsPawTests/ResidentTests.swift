import ServiceManagement
import Testing
@testable import NewsPaw

@Test func packagedLoginStatusIsNotInferredFromSocketConnectivity() {
    #expect(ResidentState.status(.notRegistered) == .off)
    #expect(ResidentState.status(.requiresApproval) == .approval)
    #expect(ResidentState.status(.enabled) == .on)
    #expect(ResidentAgent().state == .notPackaged)
}

@Test func freshPackagedRegistrationAllowsAMissingServiceRecord() {
    #expect(ResidentState.status(.notRegistered).canRegister)
    #expect(ResidentState.status(.notFound).canRegister)
    #expect(!ResidentState.status(.enabled).canRegister)
    #expect(!ResidentState.status(.requiresApproval).canRegister)
    #expect(!ResidentState.notPackaged.canRegister)
    #expect(!ResidentState.unavailable.canRegister)
}
