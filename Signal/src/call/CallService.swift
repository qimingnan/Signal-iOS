//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import WebRTC
import SignalServiceKit
import SignalMessaging

/**
 * `CallService` is a global singleton that manages the state of WebRTC-backed Signal Calls
 * (as opposed to legacy "RedPhone Calls").
 *
 * It serves as a connection between the `CallUIAdapter` and the `PeerConnectionClient`.
 *
 * ## Signaling
 *
 * Signaling refers to the setup and tear down of the connection. Before the connection is established, this must happen
 * out of band (using Signal Service), but once the connection is established it's possible to publish updates 
 * (like hangup) via the established channel.
 *
 * Signaling state is synchronized on the main thread and only mutated in the handleXXX family of methods.
 *
 * Following is a high level process of the exchange of messages that takes place during call signaling.
 *
 * ### Key
 *
 * --[SOMETHING]--> represents a message of type "Something" sent from the caller to the callee
 * <--[SOMETHING]-- represents a message of type "Something" sent from the callee to the caller
 * SS: Message sent via Signal Service
 * DC: Message sent via WebRTC Data Channel
 *
 * ### Message Exchange / State Flow Overview
 *
 * |          Caller            |          Callee         |
 * +----------------------------+-------------------------+
 * Start outgoing call: `handleOutgoingCall`...
                        --[SS.CallOffer]-->
 * ...and start generating ICE updates.
 * As ICE candidates are generated, `handleLocalAddedIceCandidate` is called.
 * and we *store* the ICE updates for later.
 *
 *                                      Received call offer: `handleReceivedOffer`
 *                                         Send call answer
 *                     <--[SS.CallAnswer]--
 *                          Start generating ICE updates.
 *                          As they are generated `handleLocalAddedIceCandidate` is called
                            which immediately sends the ICE updates to the Caller.
 *                     <--[SS.ICEUpdate]-- (sent multiple times)
 *
 * Received CallAnswer: `handleReceivedAnswer`
 * So send any stored ice updates (and send future ones immediately)
 *                     --[SS.ICEUpdates]-->
 *
 *     Once compatible ICE updates have been exchanged...
 *                both parties: `handleIceConnected`
 *
 * Show remote ringing UI
 *                          Connect to offered Data Channel
 *                                    Show incoming call UI.
 *
 *                                   If callee answers Call
 *                                   send connected message
 *                   <--[DC.ConnectedMesage]--
 * Received connected message
 * Show Call is connected.
 *
 * Hang up (this could equally be sent by the Callee)
 *                      --[DC.Hangup]-->
 *                      --[SS.Hangup]-->
 */

enum CallError: Error {
    case providerReset
    case assertionError(description: String)
    case disconnected
    case externalError(underlyingError: Error)
    case timeout(description: String)
    case obsoleteCall(description: String)
}

// Should be roughly synced with Android client for consistency
private let connectingTimeoutSeconds: TimeInterval = 120

// All Observer methods will be invoked from the main thread.
protocol CallServiceObserver: class {
    /**
     * Fired whenever the call changes.
     */
    func didUpdateCall(call: SignalCall?)

    /**
     * Fired whenever the local or remote video track become active or inactive.
     */
    func didUpdateVideoTracks(call: SignalCall?,
                              localVideoTrack: RTCVideoTrack?,
                              remoteVideoTrack: RTCVideoTrack?)
}

// Gather all per-call state in one place.
private class SignalCallData: NSObject {
    public let call: SignalCall

    // Used to coordinate promises across delegate methods
    let fulfillCallConnectedPromise: (() -> Void)
    let rejectCallConnectedPromise: ((Error) -> Void)
    let callConnectedPromise: Promise<Void>

    // Used to ensure any received ICE messages wait until the peer connection client is set up.
    let fulfillPeerConnectionClientPromise: (() -> Void)
    let rejectPeerConnectionClientPromise: ((Error) -> Void)
    let peerConnectionClientPromise: Promise<Void>

    // Used to ensure CallOffer was sent before sending any ICE updates.
    let fulfillReadyToSendIceUpdatesPromise: (() -> Void)
    let rejectReadyToSendIceUpdatesPromise: ((Error) -> Void)
    let readyToSendIceUpdatesPromise: Promise<Void>

    weak var localVideoTrack: RTCVideoTrack? {
        didSet {
            SwiftAssertIsOnMainThread(#function)

            Logger.info("\(self.logTag) \(#function)")
        }
    }

    weak var remoteVideoTrack: RTCVideoTrack? {
        didSet {
            SwiftAssertIsOnMainThread(#function)

            Logger.info("\(self.logTag) \(#function)")
        }
    }

    var isRemoteVideoEnabled = false {
        didSet {
            SwiftAssertIsOnMainThread(#function)

            Logger.info("\(self.logTag) \(#function): \(isRemoteVideoEnabled)")
        }
    }

    var peerConnectionClient: PeerConnectionClient? {
        didSet {
            SwiftAssertIsOnMainThread(#function)

            Logger.debug("\(self.logTag) .peerConnectionClient setter: \(oldValue != nil) -> \(peerConnectionClient != nil) \(String(describing: peerConnectionClient))")
        }
    }

    required init(call: SignalCall) {
        self.call = call

        let (callConnectedPromise, fulfillCallConnectedPromise, rejectCallConnectedPromise) = Promise<Void>.pending()
        self.callConnectedPromise = callConnectedPromise
        self.fulfillCallConnectedPromise = fulfillCallConnectedPromise
        self.rejectCallConnectedPromise = rejectCallConnectedPromise

        let (peerConnectionClientPromise, fulfillPeerConnectionClientPromise, rejectPeerConnectionClientPromise) = Promise<Void>.pending()
        self.peerConnectionClientPromise = peerConnectionClientPromise
        self.fulfillPeerConnectionClientPromise = fulfillPeerConnectionClientPromise
        self.rejectPeerConnectionClientPromise = rejectPeerConnectionClientPromise

        let (readyToSendIceUpdatesPromise, fulfillReadyToSendIceUpdatesPromise, rejectReadyToSendIceUpdatesPromise) = Promise<Void>.pending()
        self.readyToSendIceUpdatesPromise = readyToSendIceUpdatesPromise
        self.fulfillReadyToSendIceUpdatesPromise = fulfillReadyToSendIceUpdatesPromise
        self.rejectReadyToSendIceUpdatesPromise = rejectReadyToSendIceUpdatesPromise

        super.init()
    }

    deinit {
        Logger.debug("[SignalCallData] deinit")
    }

    // MARK: -

    public func terminate() {
        SwiftAssertIsOnMainThread(#function)

        Logger.debug("\(self.logTag) in \(#function)")

        self.call.removeAllObservers()

        // In case we're still waiting on this promise somewhere, we need to reject it to avoid a memory leak.
        // There is no harm in rejecting a previously fulfilled promise.
        rejectCallConnectedPromise(CallError.obsoleteCall(description: "Terminating call"))

        // In case we're still waiting on the peer connection setup somewhere, we need to reject it to avoid a memory leak.
        // There is no harm in rejecting a previously fulfilled promise.
        rejectPeerConnectionClientPromise(CallError.obsoleteCall(description: "Terminating call"))

        // In case we're still waiting on this promise somewhere, we need to reject it to avoid a memory leak.
        // There is no harm in rejecting a previously fulfilled promise.
        rejectReadyToSendIceUpdatesPromise(CallError.obsoleteCall(description: "Terminating call"))

        peerConnectionClient?.terminate()
        Logger.debug("\(self.logTag) setting peerConnectionClient in \(#function)")
    }
}

// This class' state should only be accessed on the main queue.
@objc class CallService: NSObject, CallObserver, PeerConnectionClientDelegate {

    // MARK: - Properties

    var observers = [Weak<CallServiceObserver>]()

    // MARK: Dependencies

    private let accountManager: AccountManager
    private let messageSender: MessageSender
    private let contactsManager: OWSContactsManager
    private let primaryStorage: OWSPrimaryStorage

    // Exposed by environment.m
    internal let notificationsAdapter: CallNotificationsAdapter
    internal var callUIAdapter: CallUIAdapter!

    // MARK: Class

    static let fallbackIceServer = RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])

    // MARK: Ivars

    fileprivate var callData: SignalCallData? {
        didSet {
            SwiftAssertIsOnMainThread(#function)

            oldValue?.call.removeObserver(self)
            callData?.call.addObserverAndSyncState(observer: self)

            updateIsVideoEnabled()

            // Prevent device from sleeping while we have an active call.
            if oldValue != callData {
                if let oldValue = oldValue {
                    DeviceSleepManager.sharedInstance.removeBlock(blockObject: oldValue)
                }
                stopAnyCallTimer()
                if let callData = callData {
                    DeviceSleepManager.sharedInstance.addBlock(blockObject: callData)
                    self.startCallTimer()
                }
            }

            Logger.debug("\(self.logTag) .callData setter: \(oldValue?.call.identifiersForLogs as Optional) -> \(callData?.call.identifiersForLogs as Optional)")

            for observer in observers {
                observer.value?.didUpdateCall(call: callData?.call)
            }
        }
    }

    var call: SignalCall? {
        get {
            SwiftAssertIsOnMainThread(#function)

            return callData?.call
        }
    }
    var peerConnectionClient: PeerConnectionClient? {
        get {
            SwiftAssertIsOnMainThread(#function)

            return callData?.peerConnectionClient
        }
    }
    var localVideoTrack: RTCVideoTrack? {
        get {
            SwiftAssertIsOnMainThread(#function)

            return callData?.localVideoTrack
        }
    }
    var remoteVideoTrack: RTCVideoTrack? {
        get {
            SwiftAssertIsOnMainThread(#function)

            return callData?.remoteVideoTrack
        }
    }
    var isRemoteVideoEnabled: Bool {
        get {
            SwiftAssertIsOnMainThread(#function)

            guard let callData = callData else {
                return false
            }
            return callData.isRemoteVideoEnabled
        }
    }

    required init(accountManager: AccountManager, contactsManager: OWSContactsManager, messageSender: MessageSender, notificationsAdapter: CallNotificationsAdapter) {
        self.accountManager = accountManager
        self.contactsManager = contactsManager
        self.messageSender = messageSender
        self.notificationsAdapter = notificationsAdapter
        self.primaryStorage = OWSPrimaryStorage.shared()

        super.init()

        SwiftSingletons.register(self)

        self.createCallUIAdapter()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didEnterBackground),
                                               name: NSNotification.Name.OWSApplicationDidEnterBackground,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didBecomeActive),
                                               name: NSNotification.Name.OWSApplicationDidBecomeActive,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func didEnterBackground() {
        SwiftAssertIsOnMainThread(#function)
        self.updateIsVideoEnabled()
    }

    func didBecomeActive() {
        SwiftAssertIsOnMainThread(#function)
        self.updateIsVideoEnabled()
    }

    /**
     * Choose whether to use CallKit or a Notification backed interface for calling.
     */
    public func createCallUIAdapter() {
        SwiftAssertIsOnMainThread(#function)

        if self.call != nil {
            Logger.warn("\(self.logTag) ending current call in \(#function). Did user toggle callkit preference while in a call?")
            self.terminateCall()
        }
        self.callUIAdapter = CallUIAdapter(callService: self, contactsManager: self.contactsManager, notificationsAdapter: self.notificationsAdapter)
    }

    // MARK: - Service Actions

    /**
     * Initiate an outgoing call.
     */
    public func handleOutgoingCall(_ call: SignalCall) -> Promise<Void> {
        SwiftAssertIsOnMainThread(#function)

        guard self.call == nil else {
            let errorDescription = "\(self.logTag) call was unexpectedly already set."
            Logger.error(errorDescription)
            call.state = .localFailure
            OWSProdError(OWSAnalyticsEvents.callServiceCallAlreadySet(), file: #file, function: #function, line: #line)
            return Promise(error: CallError.assertionError(description: errorDescription))
        }

        let callData = SignalCallData(call: call)
        self.callData = callData

        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: call.remotePhoneNumber, callType: RPRecentCallTypeOutgoingIncomplete, in: call.thread)
        callRecord.save()
        call.callRecord = callRecord

        let promise = getIceServers().then { iceServers -> Promise<HardenedRTCSessionDescription> in
            Logger.debug("\(self.logTag) got ice servers:\(iceServers) for call: \(call.identifiersForLogs)")

            guard self.call == call else {
                throw CallError.obsoleteCall(description: "obsolete call in \(#function)")
            }

            guard callData.peerConnectionClient == nil else {
                let errorDescription = "\(self.logTag) peerconnection was unexpectedly already set."
                Logger.error(errorDescription)
                OWSProdError(OWSAnalyticsEvents.callServicePeerConnectionAlreadySet(), file: #file, function: #function, line: #line)
                throw CallError.assertionError(description: errorDescription)
            }

            let useTurnOnly = Environment.current().preferences.doCallsHideIPAddress()

            let peerConnectionClient = PeerConnectionClient(iceServers: iceServers, delegate: self, callDirection: .outgoing, useTurnOnly: useTurnOnly)
            Logger.debug("\(self.logTag) setting peerConnectionClient in \(#function) for call: \(call.identifiersForLogs)")
            callData.peerConnectionClient = peerConnectionClient
            callData.fulfillPeerConnectionClientPromise()

            return peerConnectionClient.createOffer()
        }.then { (sessionDescription: HardenedRTCSessionDescription) -> Promise<Void> in
            guard self.call == call else {
                throw CallError.obsoleteCall(description: "obsolete call in \(#function)")
            }
            guard let peerConnectionClient = self.peerConnectionClient else {
                owsFail("Missing peerConnectionClient in \(#function)")
                throw CallError.obsoleteCall(description: "Missing peerConnectionClient in \(#function)")
            }

            return peerConnectionClient.setLocalSessionDescription(sessionDescription).then {
                let offerMessage = OWSCallOfferMessage(callId: call.signalingId, sessionDescription: sessionDescription.sdp)
                let callMessage = OWSOutgoingCallMessage(thread: call.thread, offerMessage: offerMessage)
                return self.messageSender.sendPromise(message: callMessage)
            }
        }.then {
            guard self.call == call else {
                throw CallError.obsoleteCall(description: "obsolete call in \(#function)")
            }

            // For outgoing calls, wait until call offer is sent before we send any ICE updates, to ensure message ordering for
            // clients that don't support receiving ICE updates before receiving the call offer.
            self.readyToSendIceUpdates(call: call)

            // Don't let the outgoing call ring forever. We don't support inbound ringing forever anyway.
            let timeout: Promise<Void> = after(interval: connectingTimeoutSeconds).then { () -> Void in
                // This code will always be called, whether or not the call has timed out.
                // However, if the call has already connected, the `race` promise will have already been
                // fulfilled. Rejecting an already fulfilled promise is a no-op.
                throw CallError.timeout(description: "timed out waiting to receive call answer")
            }

            return race(timeout, callData.callConnectedPromise)
        }.then {
            Logger.info(self.call == call
                ? "\(self.logTag) outgoing call connected: \(call.identifiersForLogs)."
                : "\(self.logTag) obsolete outgoing call connected: \(call.identifiersForLogs).")
        }.catch { error in
            Logger.error("\(self.logTag) placing call \(call.identifiersForLogs) failed with error: \(error)")

            if let callError = error as? CallError {
                if case .timeout = callError {
                    OWSProdInfo(OWSAnalyticsEvents.callServiceErrorTimeoutWhileConnectingOutgoing(), file: #file, function: #function, line: #line)
                }
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorOutgoingConnectionFailedInternal(), file: #file, function: #function, line: #line)
                self.handleFailedCall(failedCall: call, error: callError)
            } else {
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorOutgoingConnectionFailedExternal(), file: #file, function: #function, line: #line)
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(failedCall: call, error: externalError)
            }
        }
        promise.retainUntilComplete()
        return promise
    }

    func readyToSendIceUpdates(call: SignalCall) {
        SwiftAssertIsOnMainThread(#function)

        guard let callData = self.callData else {
            self.handleFailedCall(failedCall: call, error: .obsoleteCall(description:"obsolete call in \(#function)"))
            return
        }
        guard callData.call == call else {
            Logger.warn("\(self.logTag) ignoring \(#function) for call other than current call")
            return
        }

        callData.fulfillReadyToSendIceUpdatesPromise()
    }

    /**
     * Called by the call initiator after receiving a CallAnswer from the callee.
     */
    public func handleReceivedAnswer(thread: TSContactThread, callId: UInt64, sessionDescription: String) {
        Logger.info("\(self.logTag) received call answer for call: \(callId) thread: \(thread.contactIdentifier())")
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            Logger.warn("\(self.logTag) ignoring obsolete call: \(callId) in \(#function)")
            return
        }

        guard call.signalingId == callId else {
            Logger.warn("\(self.logTag) ignoring mismatched call: \(callId) currentCall: \(call.signalingId) in \(#function)")
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            OWSProdError(OWSAnalyticsEvents.callServicePeerConnectionMissing(), file: #file, function: #function, line: #line)
            handleFailedCall(failedCall: call, error: CallError.assertionError(description: "peerConnectionClient was unexpectedly nil in \(#function)"))
            return
        }

        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sessionDescription)
        let setDescriptionPromise = peerConnectionClient.setRemoteSessionDescription(sessionDescription).then {
            Logger.debug("\(self.logTag) successfully set remote description")
        }.catch { error in
            if let callError = error as? CallError {
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorHandleReceivedErrorInternal(), file: #file, function: #function, line: #line)
                self.handleFailedCall(failedCall: call, error: callError)
            } else {
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorHandleReceivedErrorExternal(), file: #file, function: #function, line: #line)
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(failedCall: call, error: externalError)
            }
        }
        setDescriptionPromise.retainUntilComplete()
    }

    /**
     * User didn't answer incoming call
     */
    public func handleMissedCall(_ call: SignalCall) {
        SwiftAssertIsOnMainThread(#function)

        // Insert missed call record
        if let callRecord = call.callRecord {
            if callRecord.callType == RPRecentCallTypeIncoming {
                callRecord.updateCallType(RPRecentCallTypeMissed)
            }
        } else {
            call.callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(),
                                     withCallNumber: call.thread.contactIdentifier(),
                                     callType: RPRecentCallTypeMissed,
                                     in: call.thread)
        }

        assert(call.callRecord != nil)
        call.callRecord?.save()

        self.callUIAdapter.reportMissedCall(call)
    }

    /**
     * Received a call while already in another call.
     */
    private func handleLocalBusyCall(_ call: SignalCall) {
        Logger.info("\(self.logTag) \(#function) for call: \(call.identifiersForLogs) thread: \(call.thread.contactIdentifier())")
        SwiftAssertIsOnMainThread(#function)

        let busyMessage = OWSCallBusyMessage(callId: call.signalingId)
        let callMessage = OWSOutgoingCallMessage(thread: call.thread, busyMessage: busyMessage)
        let sendPromise = messageSender.sendPromise(message: callMessage)
        sendPromise.retainUntilComplete()

        handleMissedCall(call)
    }

    /**
     * The callee was already in another call.
     */
    public func handleRemoteBusy(thread: TSContactThread, callId: UInt64) {
        Logger.info("\(self.logTag) \(#function) for thread: \(thread.contactIdentifier())")
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            Logger.warn("\(self.logTag) ignoring obsolete call: \(callId) in \(#function)")
            return
        }

        guard call.signalingId == callId else {
            Logger.warn("\(self.logTag) ignoring mismatched call: \(callId) currentCall: \(call.signalingId) in \(#function)")
            return
        }

        guard thread.contactIdentifier() == call.remotePhoneNumber else {
            Logger.warn("\(self.logTag) ignoring obsolete call in \(#function)")
            return
        }

        call.state = .remoteBusy
        callUIAdapter.remoteBusy(call)
        terminateCall()
    }

    /**
     * Received an incoming call offer. We still have to complete setting up the Signaling channel before we notify
     * the user of an incoming call.
     */
    public func handleReceivedOffer(thread: TSContactThread, callId: UInt64, sessionDescription callerSessionDescription: String) {
        SwiftAssertIsOnMainThread(#function)

        let newCall = SignalCall.incomingCall(localId: UUID(), remotePhoneNumber: thread.contactIdentifier(), signalingId: callId)

        Logger.info("\(self.logTag) receivedCallOffer: \(newCall.identifiersForLogs)")

        let untrustedIdentity = OWSIdentityManager.shared().untrustedIdentityForSending(toRecipientId: thread.contactIdentifier())

        guard untrustedIdentity == nil else {
            Logger.warn("\(self.logTag) missed a call due to untrusted identity: \(newCall.identifiersForLogs)")

            let callerName = self.contactsManager.displayName(forPhoneIdentifier: thread.contactIdentifier())

            switch untrustedIdentity!.verificationState {
            case .verified:
                owsFail("\(self.logTag) shouldn't have missed a call due to untrusted identity if the identity is verified")
                self.notificationsAdapter.presentMissedCall(newCall, callerName: callerName)
            case .default:
                self.notificationsAdapter.presentMissedCallBecauseOfNewIdentity(call: newCall, callerName: callerName)
            case .noLongerVerified:
                self.notificationsAdapter.presentMissedCallBecauseOfNoLongerVerifiedIdentity(call: newCall, callerName: callerName)
            }

            let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(),
                                    withCallNumber: thread.contactIdentifier(),
                                    callType: RPRecentCallTypeMissedBecauseOfChangedIdentity,
                                    in: thread)
            assert(newCall.callRecord == nil)
            newCall.callRecord = callRecord
            callRecord.save()

            terminateCall()

            return
        }

        guard self.call == nil else {
            let existingCall = self.call!

            // TODO on iOS10+ we can use CallKit to swap calls rather than just returning busy immediately.
            Logger.info("\(self.logTag) receivedCallOffer: \(newCall.identifiersForLogs) but we're already in call: \(existingCall.identifiersForLogs)")

            handleLocalBusyCall(newCall)

            if existingCall.remotePhoneNumber == newCall.remotePhoneNumber {
                Logger.info("\(self.logTag) handling call from current call user as remote busy.: \(newCall.identifiersForLogs) but we're already in call: \(existingCall.identifiersForLogs)")

                // If we're receiving a new call offer from the user we already think we have a call with,
                // terminate our current call to get back to a known good state.  If they call back, we'll 
                // be ready.
                // 
                // TODO: Auto-accept this incoming call if our current call was either a) outgoing or 
                // b) never connected.  There will be a bit of complexity around making sure that two
                // parties that call each other at the same time end up connected.
                switch existingCall.state {
                case .idle, .dialing, .remoteRinging:
                    // If both users are trying to call each other at the same time,
                    // both should see busy.
                    handleRemoteBusy(thread: existingCall.thread, callId: existingCall.signalingId)
                case .answering, .localRinging, .connected, .localFailure, .localHangup, .remoteHangup, .remoteBusy, .reconnecting:
                    // If one user calls another while the other has a "vestigial" call with
                    // that same user, fail the old call.
                    terminateCall()
                }
            }

            return
        }

        Logger.info("\(self.logTag) starting new call: \(newCall.identifiersForLogs)")

        let callData = SignalCallData(call: newCall)
        self.callData = callData

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "\(#function)", completionBlock: { [weak self] status in
            SwiftAssertIsOnMainThread(#function)

            guard status == .expired else {
                return
            }

            guard let strongSelf = self else {
                return
            }
            let timeout = CallError.timeout(description: "background task time ran out before call connected.")

            guard strongSelf.call == newCall else {
                Logger.warn("\(strongSelf.logTag) ignoring obsolete call in \(#function)")
                return
            }
            strongSelf.handleFailedCall(failedCall: newCall, error: timeout)
        })

        let incomingCallPromise = firstly {
            return getIceServers()
        }.then { (iceServers: [RTCIceServer]) -> Promise<HardenedRTCSessionDescription> in
            // FIXME for first time call recipients I think we'll see mic/camera permission requests here,
            // even though, from the users perspective, no incoming call is yet visible.
            guard self.call == newCall else {
                throw CallError.obsoleteCall(description: "getIceServers() response for obsolete call")
            }
            assert(self.peerConnectionClient == nil, "Unexpected PeerConnectionClient instance")

            // For contacts not stored in our system contacts, we assume they are an unknown caller, and we force
            // a TURN connection, so as not to reveal any connectivity information (IP/port) to the caller.
            let unknownCaller = self.contactsManager.signalAccount(forRecipientId: thread.contactIdentifier()) == nil

            let useTurnOnly = unknownCaller || Environment.current().preferences.doCallsHideIPAddress()

            Logger.debug("\(self.logTag) setting peerConnectionClient in \(#function) for: \(newCall.identifiersForLogs)")
            let peerConnectionClient = PeerConnectionClient(iceServers: iceServers, delegate: self, callDirection: .incoming, useTurnOnly: useTurnOnly)
            callData.peerConnectionClient = peerConnectionClient
            callData.fulfillPeerConnectionClientPromise()

            let offerSessionDescription = RTCSessionDescription(type: .offer, sdp: callerSessionDescription)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

            // Find a sessionDescription compatible with my constraints and the remote sessionDescription
            return peerConnectionClient.negotiateSessionDescription(remoteDescription: offerSessionDescription, constraints: constraints)
        }.then { (negotiatedSessionDescription: HardenedRTCSessionDescription) in
            Logger.debug("\(self.logTag) set the remote description for: \(newCall.identifiersForLogs)")

            guard self.call == newCall else {
                throw CallError.obsoleteCall(description: "negotiateSessionDescription() response for obsolete call")
            }

            let answerMessage = OWSCallAnswerMessage(callId: newCall.signalingId, sessionDescription: negotiatedSessionDescription.sdp)
            let callAnswerMessage = OWSOutgoingCallMessage(thread: thread, answerMessage: answerMessage)

            return self.messageSender.sendPromise(message: callAnswerMessage)
        }.then {
            guard self.call == newCall else {
                throw CallError.obsoleteCall(description: "sendPromise(message: ) response for obsolete call")
            }
            Logger.debug("\(self.logTag) successfully sent callAnswerMessage for: \(newCall.identifiersForLogs)")

            // There's nothing technically forbidding receiving ICE updates before receiving the CallAnswer, but this
            // a more intuitive ordering.
            self.readyToSendIceUpdates(call: newCall)

            let timeout: Promise<Void> = after(interval: connectingTimeoutSeconds).then { () -> Void in
                // rejecting a promise by throwing is safely a no-op if the promise has already been fulfilled
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorTimeoutWhileConnectingIncoming(), file: #file, function: #function, line: #line)
                throw CallError.timeout(description: "timed out waiting for call to connect")
            }

            // This will be fulfilled (potentially) by the RTCDataChannel delegate method
            return race(callData.callConnectedPromise, timeout)
        }.then {
            Logger.info(self.call == newCall
                ? "\(self.logTag) incoming call connected: \(newCall.identifiersForLogs)."
                : "\(self.logTag) obsolete incoming call connected: \(newCall.identifiersForLogs).")
        }.catch { error in
            guard self.call == newCall else {
                Logger.debug("\(self.logTag) ignoring error: \(error)  for obsolete call: \(newCall.identifiersForLogs).")
                return
            }
            if let callError = error as? CallError {
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorIncomingConnectionFailedInternal(), file: #file, function: #function, line: #line)
                self.handleFailedCall(failedCall: newCall, error: callError)
            } else {
                OWSProdInfo(OWSAnalyticsEvents.callServiceErrorIncomingConnectionFailedExternal(), file: #file, function: #function, line: #line)
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(failedCall: newCall, error: externalError)
            }
        }.always {
            Logger.debug("\(self.logTag) ending background task awaiting inbound call connection")

            assert(backgroundTask != nil)
            backgroundTask = nil
        }
        incomingCallPromise.retainUntilComplete()
    }

    /**
     * Remote client (could be caller or callee) sent us a connectivity update
     */
    public func handleRemoteAddedIceCandidate(thread: TSContactThread, callId: UInt64, sdp: String, lineIndex: Int32, mid: String) {
        SwiftAssertIsOnMainThread(#function)
        Logger.verbose("\(logTag) \(#function) callId: \(callId)")

        guard let callData = self.callData else {
            Logger.info("\(logTag) ignoring remote ice update, since there is no current call.")
            return
        }

        callData.peerConnectionClientPromise.then { () -> Void in
            SwiftAssertIsOnMainThread(#function)

            guard let call = self.call else {
                Logger.warn("ignoring remote ice update for thread: \(String(describing: thread.uniqueId)) since there is no current call. Call already ended?")
                return
            }

            guard call.signalingId == callId else {
                Logger.warn("\(self.logTag) ignoring mismatched call: \(callId) currentCall: \(call.signalingId) in \(#function)")
                return
            }

            guard thread.contactIdentifier() == call.thread.contactIdentifier() else {
                Logger.warn("ignoring remote ice update for thread: \(String(describing: thread.uniqueId)) due to thread mismatch. Call already ended?")
                return
            }

            guard let peerConnectionClient = self.peerConnectionClient else {
                Logger.warn("ignoring remote ice update for thread: \(String(describing: thread.uniqueId)) since there is no current peerConnectionClient. Call already ended?")
                return
            }

            Logger.verbose("\(self.logTag) \(#function) addRemoteIceCandidate")
            peerConnectionClient.addRemoteIceCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid))
        }.catch { error in
            OWSProdInfo(OWSAnalyticsEvents.callServiceErrorHandleRemoteAddedIceCandidate(), file: #file, function: #function, line: #line)
            Logger.error("\(self.logTag) in \(#function) peerConnectionClientPromise failed with error: \(error)")
        }.retainUntilComplete()
    }

    /**
     * Local client (could be caller or callee) generated some connectivity information that we should send to the 
     * remote client.
     */
    private func handleLocalAddedIceCandidate(_ iceCandidate: RTCIceCandidate) {
        SwiftAssertIsOnMainThread(#function)

        guard let callData = self.callData else {
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            self.handleFailedCurrentCall(error: CallError.assertionError(description: "ignoring local ice candidate, since there is no current call."))
            return
        }
        let call = callData.call

        // Wait until we've sent the CallOffer before sending any ice updates for the call to ensure
        // intuitive message ordering for other clients.
        callData.readyToSendIceUpdatesPromise.then { () -> Void in
            guard call == self.call else {
                self.handleFailedCurrentCall(error: .obsoleteCall(description: "current call changed since we became ready to send ice updates"))
                return
            }

            guard call.state != .idle else {
                // This will only be called for the current peerConnectionClient, so
                // fail the current call.
                OWSProdError(OWSAnalyticsEvents.callServiceCallUnexpectedlyIdle(), file: #file, function: #function, line: #line)
                self.handleFailedCurrentCall(error: CallError.assertionError(description: "ignoring local ice candidate, since call is now idle."))
                return
            }

            let iceUpdateMessage = OWSCallIceUpdateMessage(callId: call.signalingId, sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid)

            Logger.info("\(self.logTag) in \(#function) sending ICE Candidate \(call.identifiersForLogs).")
            let callMessage = OWSOutgoingCallMessage(thread: call.thread, iceUpdateMessage: iceUpdateMessage)
            let sendPromise = self.messageSender.sendPromise(message: callMessage)
            sendPromise.retainUntilComplete()
        }.catch { error in
            OWSProdInfo(OWSAnalyticsEvents.callServiceErrorHandleLocalAddedIceCandidate(), file: #file, function: #function, line: #line)
            Logger.error("\(self.logTag) in \(#function) waitUntilReadyToSendIceUpdates failed with error: \(error)")
        }.retainUntilComplete()
    }

    /**
     * The clients can now communicate via WebRTC.
     *
     * Called by both caller and callee. Compatible ICE messages have been exchanged between the local and remote 
     * client.
     */
    private func handleIceConnected() {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            // This will only be called for the current peerConnectionClient, so
            // fail the current call.
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) ignoring \(#function) since there is no current call."))
            return
        }

        Logger.info("\(self.logTag) in \(#function): \(call.identifiersForLogs).")

        switch call.state {
        case .dialing:
            call.state = .remoteRinging
        case .answering:
            call.state = .localRinging
            self.callUIAdapter.reportIncomingCall(call, thread: call.thread)
        case .remoteRinging:
            Logger.info("\(self.logTag) call already ringing. Ignoring \(#function): \(call.identifiersForLogs).")
        case .connected:
            Logger.info("\(self.logTag) Call reconnected \(#function): \(call.identifiersForLogs).")
        case .reconnecting:
            call.state = .connected
        case .idle, .localRinging, .localFailure, .localHangup, .remoteHangup, .remoteBusy:
            owsFail("\(self.logTag) unexpected call state for \(#function): \(call.state): \(call.identifiersForLogs).")
        }
    }

    private func handleIceDisconnected() {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            // This will only be called for the current peerConnectionClient, so
            // fail the current call.
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) ignoring \(#function) since there is no current call."))
            return
        }

        Logger.info("\(self.logTag) in \(#function): \(call.identifiersForLogs).")

        switch call.state {
        case .remoteRinging, .localRinging:
            Logger.debug("\(self.logTag) in \(#function) disconnect while ringing... we'll keep ringing")
        case .connected:
            call.state = .reconnecting
        default:
            owsFail("\(self.logTag) unexpected call state for \(#function): \(call.state): \(call.identifiersForLogs).")
        }
    }

    /**
     * The remote client (caller or callee) ended the call.
     */
    public func handleRemoteHangup(thread: TSContactThread, callId: UInt64) {
        Logger.debug("\(self.logTag) in \(#function)")
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            // This may happen if we hang up slightly before they hang up.
            handleFailedCurrentCall(error: .obsoleteCall(description:"\(self.logTag) call was unexpectedly nil in \(#function)"))
            return
        }

        guard call.signalingId == callId else {
            Logger.warn("\(self.logTag) ignoring mismatched call: \(callId) currentCall: \(call.signalingId) in \(#function)")
            return
        }

        guard thread.contactIdentifier() == call.thread.contactIdentifier() else {
            // This can safely be ignored.
            // We don't want to fail the current call because an old call was slow to send us the hangup message.
            Logger.warn("\(self.logTag) ignoring hangup for thread: \(thread.contactIdentifier()) which is not the current call: \(call.identifiersForLogs)")
            return
        }

        Logger.info("\(self.logTag) in \(#function): \(call.identifiersForLogs).")

        switch call.state {
        case .idle, .dialing, .answering, .localRinging, .localFailure, .remoteBusy, .remoteRinging:
            handleMissedCall(call)
        case .connected, .reconnecting, .localHangup, .remoteHangup:
            Logger.info("\(self.logTag) call is finished.")
        }

        call.state = .remoteHangup
        // Notify UI
        callUIAdapter.remoteDidHangupCall(call)

        // self.call is nil'd in `terminateCall`, so it's important we update it's state *before* calling `terminateCall`
        terminateCall()
    }

    /**
     * User chose to answer call referred to by call `localId`. Used by the Callee only.
     *
     * Used by notification actions which can't serialize a call object.
     */
    public func handleAnswerCall(localId: UUID) {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            // This should never happen; return to a known good state.
            owsFail("\(self.logTag) call was unexpectedly nil in \(#function)")
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) call was unexpectedly nil in \(#function)"))
            return
        }

        guard call.localId == localId else {
            // This should never happen; return to a known good state.
            owsFail("\(self.logTag) callLocalId:\(localId) doesn't match current calls: \(call.localId)")
            OWSProdError(OWSAnalyticsEvents.callServiceCallIdMismatch(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) callLocalId:\(localId) doesn't match current calls: \(call.localId)"))
            return
        }

        self.handleAnswerCall(call)
    }

    /**
     * User chose to answer call referred to by call `localId`. Used by the Callee only.
     */
    public func handleAnswerCall(_ call: SignalCall) {
        SwiftAssertIsOnMainThread(#function)

        Logger.debug("\(self.logTag) in \(#function)")

        guard let currentCallData = self.callData else {
            OWSProdError(OWSAnalyticsEvents.callServiceCallDataMissing(), file: #file, function: #function, line: #line)
            handleFailedCall(failedCall: call, error: CallError.assertionError(description: "\(self.logTag) callData unexpectedly nil in \(#function)"))
            return
        }

        guard call == currentCallData.call else {
            // This could conceivably happen if the other party of an old call was slow to send us their answer
            // and we've subsequently engaged in another call. Don't kill the current call, but just ignore it.
            Logger.warn("\(self.logTag) ignoring \(#function) for call other than current call")
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            OWSProdError(OWSAnalyticsEvents.callServicePeerConnectionMissing(), file: #file, function: #function, line: #line)
            handleFailedCall(failedCall: call, error: CallError.assertionError(description: "\(self.logTag) missing peerconnection client in \(#function)"))
            return
        }

        Logger.info("\(self.logTag) in \(#function): \(call.identifiersForLogs).")

        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: call.remotePhoneNumber, callType: RPRecentCallTypeIncomingIncomplete, in: call.thread)
        callRecord.save()
        call.callRecord = callRecord

        let message = DataChannelMessage.forConnected(callId: call.signalingId)
        peerConnectionClient.sendDataChannelMessage(data: message.asData(), description: "connected", isCritical: true)

        handleConnectedCall(currentCallData)
    }

    /**
     * For outgoing call, when the callee has chosen to accept the call.
     * For incoming call, when the local user has chosen to accept the call.
     */
    private func handleConnectedCall(_ callData: SignalCallData) {
        Logger.info("\(self.logTag) in \(#function)")
        SwiftAssertIsOnMainThread(#function)

        guard let peerConnectionClient = callData.peerConnectionClient else {
            OWSProdError(OWSAnalyticsEvents.callServicePeerConnectionMissing(), file: #file, function: #function, line: #line)
            handleFailedCall(failedCall: call, error: CallError.assertionError(description: "\(self.logTag) peerConnectionClient unexpectedly nil in \(#function)"))
            return
        }

        Logger.info("\(self.logTag) handleConnectedCall: \(callData.call.identifiersForLogs).")

        // cancel connection timeout
        callData.fulfillCallConnectedPromise()

        callData.call.state = .connected

        // We don't risk transmitting any media until the remote client has admitted to being connected.
        ensureAudioState(call: callData.call, peerConnectionClient: peerConnectionClient)
        peerConnectionClient.setLocalVideoEnabled(enabled: shouldHaveLocalVideoTrack())
    }

    /**
     * Local user chose to decline the call vs. answering it.
     *
     * The call is referred to by call `localId`, which is included in Notification actions.
     *
     * Incoming call only.
     */
    public func handleDeclineCall(localId: UUID) {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            // This should never happen; return to a known good state.
            owsFail("\(self.logTag) call was unexpectedly nil in \(#function)")
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) call was unexpectedly nil in \(#function)"))
            return
        }

        guard call.localId == localId else {
            // This should never happen; return to a known good state.
            owsFail("\(self.logTag) callLocalId:\(localId) doesn't match current calls: \(call.localId)")
            OWSProdError(OWSAnalyticsEvents.callServiceCallIdMismatch(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) callLocalId:\(localId) doesn't match current calls: \(call.localId)"))
            return
        }

        self.handleDeclineCall(call)
    }

    /**
     * Local user chose to decline the call vs. answering it.
     *
     * Incoming call only.
     */
    public func handleDeclineCall(_ call: SignalCall) {
        SwiftAssertIsOnMainThread(#function)

        Logger.info("\(self.logTag) in \(#function): \(call.identifiersForLogs).")

        if let callRecord = call.callRecord {
            owsFail("Not expecting callrecord to already be set")
            callRecord.updateCallType(RPRecentCallTypeIncomingDeclined)
        } else {
            let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: call.remotePhoneNumber, callType: RPRecentCallTypeIncomingDeclined, in: call.thread)
            callRecord.save()
            call.callRecord = callRecord
        }

        // Currently we just handle this as a hangup. But we could offer more descriptive action. e.g. DataChannel message
        handleLocalHungupCall(call)
    }

    /**
     * Local user chose to end the call.
     *
     * Can be used for Incoming and Outgoing calls.
     */
    func handleLocalHungupCall(_ call: SignalCall) {
        SwiftAssertIsOnMainThread(#function)

        guard let currentCall = self.call else {
            Logger.info("\(self.logTag) in \(#function), but no current call. Other party hung up just before us.")

            // terminating the call might be redundant, but it shouldn't hurt.
            terminateCall()
            return
        }

        guard call == currentCall else {
            OWSProdError(OWSAnalyticsEvents.callServiceCallMismatch(), file: #file, function: #function, line: #line)
            handleFailedCall(failedCall: call, error: CallError.assertionError(description: "\(self.logTag) ignoring \(#function) for call other than current call"))
            return
        }

        Logger.info("\(self.logTag) in \(#function): \(call.identifiersForLogs).")

        call.state = .localHangup

        // TODO something like this lifted from Signal-Android.
        //        this.accountManager.cancelInFlightRequests();
        //        this.messageSender.cancelInFlightRequests();

        if let peerConnectionClient = self.peerConnectionClient {
            // Stop audio capture ASAP
            ensureAudioState(call: call, peerConnectionClient: peerConnectionClient)

            // If the call is connected, we can send the hangup via the data channel for faster hangup.
            let message = DataChannelMessage.forHangup(callId: call.signalingId)
            peerConnectionClient.sendDataChannelMessage(data: message.asData(), description: "hangup", isCritical: true)
        } else {
            Logger.info("\(self.logTag) ending call before peer connection created. Device offline or quick hangup.")
        }

        // If the call hasn't started yet, we don't have a data channel to communicate the hang up. Use Signal Service Message.
        let hangupMessage = OWSCallHangupMessage(callId: call.signalingId)
        let callMessage = OWSOutgoingCallMessage(thread: call.thread, hangupMessage: hangupMessage)
        let sendPromise = self.messageSender.sendPromise(message: callMessage).then {
            Logger.debug("\(self.logTag) successfully sent hangup call message to \(call.thread.contactIdentifier())")
        }.catch { error in
            OWSProdInfo(OWSAnalyticsEvents.callServiceErrorHandleLocalHungupCall(), file: #file, function: #function, line: #line)
            Logger.error("\(self.logTag) failed to send hangup call message to \(call.thread.contactIdentifier()) with error: \(error)")
        }
        sendPromise.retainUntilComplete()

        terminateCall()
    }

    /**
     * Local user toggled to mute audio.
     *
     * Can be used for Incoming and Outgoing calls.
     */
    func setIsMuted(call: SignalCall, isMuted: Bool) {
        SwiftAssertIsOnMainThread(#function)

        guard call == self.call else {
            // This can happen after a call has ended. Reproducible on iOS11, when the other party ends the call.
            Logger.info("\(self.logTag) ignoring mute request for obsolete call")
            return
        }

        call.isMuted = isMuted

        guard let peerConnectionClient = self.peerConnectionClient else {
            // The peer connection might not be created yet.
            return
        }

        ensureAudioState(call: call, peerConnectionClient: peerConnectionClient)
    }

    /**
     * Local user toggled to hold call. Currently only possible via CallKit screen,
     * e.g. when another Call comes in.
     */
    func setIsOnHold(call: SignalCall, isOnHold: Bool) {
        SwiftAssertIsOnMainThread(#function)

        guard call == self.call else {
            Logger.info("\(self.logTag) ignoring held request for obsolete call")
            return
        }

        call.isOnHold = isOnHold

        guard let peerConnectionClient = self.peerConnectionClient else {
            // The peer connection might not be created yet.
            return
        }

        ensureAudioState(call: call, peerConnectionClient: peerConnectionClient)
    }

    func ensureAudioState(call: SignalCall, peerConnectionClient: PeerConnectionClient) {
        guard call.state == .connected else {
            peerConnectionClient.setAudioEnabled(enabled: false)
            return
        }
        guard !call.isMuted else {
            peerConnectionClient.setAudioEnabled(enabled: false)
            return
        }
        guard !call.isOnHold else {
            peerConnectionClient.setAudioEnabled(enabled: false)
            return
        }

        peerConnectionClient.setAudioEnabled(enabled: true)
    }

    /**
     * Local user toggled video.
     *
     * Can be used for Incoming and Outgoing calls.
     */
    func setHasLocalVideo(hasLocalVideo: Bool) {
        SwiftAssertIsOnMainThread(#function)

        guard let frontmostViewController = UIApplication.shared.frontmostViewController else {
            owsFail("\(self.logTag) could not identify frontmostViewController in \(#function)")
            return
        }

        frontmostViewController.ows_ask(forCameraPermissions: { [weak self] granted in
            guard let strongSelf = self else {
                return
            }

            if (granted) {
                // Success callback; camera permissions are granted.
                strongSelf.setHasLocalVideoWithCameraPermissions(hasLocalVideo: hasLocalVideo)
            } else {
                // Failed callback; camera permissions are _NOT_ granted.

                // We don't need to worry about the user granting or remoting this permission
                // during a call while the app is in the background, because changing this
                // permission kills the app.
                OWSAlerts.showAlert(title: NSLocalizedString("MISSING_CAMERA_PERMISSION_TITLE", comment: "Alert title when camera is not authorized"),
                                    message: NSLocalizedString("MISSING_CAMERA_PERMISSION_MESSAGE", comment: "Alert body when camera is not authorized"))
            }
        })
    }

    private func setHasLocalVideoWithCameraPermissions(hasLocalVideo: Bool) {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            // This should never happen; return to a known good state.
            owsFail("\(self.logTag) call was unexpectedly nil in \(#function)")
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) call unexpectedly nil in \(#function)"))
            return
        }

        call.hasLocalVideo = hasLocalVideo

        guard let peerConnectionClient = self.peerConnectionClient else {
            // The peer connection might not be created yet.
            return
        }

        if call.state == .connected {
            peerConnectionClient.setLocalVideoEnabled(enabled: shouldHaveLocalVideoTrack())
        }
    }

    func handleCallKitStartVideo() {
        SwiftAssertIsOnMainThread(#function)

        self.setHasLocalVideo(hasLocalVideo: true)
    }

    func setCameraSource(call: SignalCall, useBackCamera: Bool) {
        SwiftAssertIsOnMainThread(#function)

        guard call == self.call else {
            owsFail("\(logTag) in \(#function) for non-current call.")
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            owsFail("\(logTag) in \(#function) peerConnectionClient was unexpectedly nil")
            return
        }

        peerConnectionClient.setCameraSource(useBackCamera: useBackCamera)
    }

    /**
     * Local client received a message on the WebRTC data channel. 
     *
     * The WebRTC data channel is a faster signaling channel than out of band Signal Service messages. Once it's 
     * established we use it to communicate further signaling information. The one sort-of exception is that with 
     * hangup messages we redundantly send a Signal Service hangup message, which is more reliable, and since the hangup 
     * action is idemptotent, there's no harm done.
     *
     * Used by both Incoming and Outgoing calls.
     */
    private func handleDataChannelMessage(_ message: OWSWebRTCProtosData) {
        SwiftAssertIsOnMainThread(#function)

        guard let callData = self.callData else {
            // This should never happen; return to a known good state.
            owsFail("\(self.logTag) received data message, but there is no current call. Ignoring.")
            OWSProdError(OWSAnalyticsEvents.callServiceCallMissing(), file: #file, function: #function, line: #line)
            handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) received data message, but there is no current call. Ignoring."))
            return
        }
        let call = callData.call

        if message.hasConnected() {
            Logger.debug("\(self.logTag) remote participant sent Connected via data channel: \(call.identifiersForLogs).")

            let connected = message.connected!

            guard connected.id == call.signalingId else {
                // This should never happen; return to a known good state.
                owsFail("\(self.logTag) received connected message for call with id:\(connected.id) but current call has id:\(call.signalingId)")
                OWSProdError(OWSAnalyticsEvents.callServiceCallIdMismatch(), file: #file, function: #function, line: #line)
                handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) received connected message for call with id:\(connected.id) but current call has id:\(call.signalingId)"))
                return
            }

            self.callUIAdapter.recipientAcceptedCall(call)
            handleConnectedCall(callData)

        } else if message.hasHangup() {
            Logger.debug("\(self.logTag) remote participant sent Hangup via data channel: \(call.identifiersForLogs).")

            let hangup = message.hangup!

            guard hangup.id == call.signalingId else {
                // This should never happen; return to a known good state.
                owsFail("\(self.logTag) received hangup message for call with id:\(hangup.id) but current call has id:\(call.signalingId)")
                OWSProdError(OWSAnalyticsEvents.callServiceCallIdMismatch(), file: #file, function: #function, line: #line)
                handleFailedCurrentCall(error: CallError.assertionError(description: "\(self.logTag) received hangup message for call with id:\(hangup.id) but current call has id:\(call.signalingId)"))
                return
            }

            handleRemoteHangup(thread: call.thread, callId: hangup.id)
        } else if message.hasVideoStreamingStatus() {
            Logger.debug("\(self.logTag) remote participant sent VideoStreamingStatus via data channel: \(call.identifiersForLogs).")

            callData.isRemoteVideoEnabled = message.videoStreamingStatus.enabled()
            self.fireDidUpdateVideoTracks()
        } else {
            Logger.info("\(self.logTag) received unknown or empty DataChannelMessage: \(call.identifiersForLogs).")
        }
    }

    // MARK: - PeerConnectionClientDelegate

    /**
     * The connection has been established. The clients can now communicate.
     */
    internal func peerConnectionClientIceConnected(_ peerConnectionClient: PeerConnectionClient) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        self.handleIceConnected()
    }

    func peerConnectionClientIceDisconnected(_ peerconnectionClient: PeerConnectionClient) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        self.handleIceDisconnected()
    }

    /**
     * The connection failed to establish. The clients will not be able to communicate.
     */
    internal func peerConnectionClientIceFailed(_ peerConnectionClient: PeerConnectionClient) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        // Return to a known good state.
        self.handleFailedCurrentCall(error: CallError.disconnected)
    }

    /**
     * During the Signaling process each client generates IceCandidates locally, which contain information about how to
     * reach the local client via the internet. The delegate must shuttle these IceCandates to the other (remote) client
     * out of band, as part of establishing a connection over WebRTC.
     */
    internal func peerConnectionClient(_ peerConnectionClient: PeerConnectionClient, addedLocalIceCandidate iceCandidate: RTCIceCandidate) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        self.handleLocalAddedIceCandidate(iceCandidate)
    }

    /**
     * Once the peerconnection is established, we can receive messages via the data channel, and notify the delegate.
     */
    internal func peerConnectionClient(_ peerConnectionClient: PeerConnectionClient, received dataChannelMessage: OWSWebRTCProtosData) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        self.handleDataChannelMessage(dataChannelMessage)
    }

    internal func peerConnectionClient(_ peerConnectionClient: PeerConnectionClient, didUpdateLocal videoTrack: RTCVideoTrack?) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }
        guard let callData = callData else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        callData.localVideoTrack = videoTrack
        fireDidUpdateVideoTracks()
    }

    internal func peerConnectionClient(_ peerConnectionClient: PeerConnectionClient, didUpdateRemote videoTrack: RTCVideoTrack?) {
        SwiftAssertIsOnMainThread(#function)

        guard peerConnectionClient == self.peerConnectionClient else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }
        guard let callData = callData else {
            Logger.debug("\(self.logTag) \(#function) Ignoring event from obsolete peerConnectionClient")
            return
        }

        callData.remoteVideoTrack = videoTrack
        fireDidUpdateVideoTracks()
    }

    // MARK: -

    /**
     * RTCIceServers are used when attempting to establish an optimal connection to the other party. SignalService supplies
     * a list of servers, plus we have fallback servers hardcoded in the app.
     */
    private func getIceServers() -> Promise<[RTCIceServer]> {
        SwiftAssertIsOnMainThread(#function)

        return firstly {
            return accountManager.getTurnServerInfo()
        }.then { turnServerInfo -> [RTCIceServer] in
            Logger.debug("\(self.logTag) got turn server urls: \(turnServerInfo.urls)")

            return turnServerInfo.urls.map { url in
                if url.hasPrefix("turn") {
                    // Only "turn:" servers require authentication. Don't include the credentials to other ICE servers
                    // as 1.) they aren't used, and 2.) the non-turn servers might not be under our control.
                    // e.g. we use a public fallback STUN server.
                    return RTCIceServer(urlStrings: [url], username: turnServerInfo.username, credential: turnServerInfo.password)
                } else {
                    return RTCIceServer(urlStrings: [url])
                }
            } + [CallService.fallbackIceServer]
        }.recover { error -> [RTCIceServer] in
            Logger.error("\(self.logTag) fetching ICE servers failed with error: \(error)")
            Logger.warn("\(self.logTag) using fallback ICE Servers")

            return [CallService.fallbackIceServer]
        }
    }

    // This method should be called when either: a) we know or assume that
    // the error is related to the current call. b) the error is so serious
    // that we want to terminate the current call (if any) in order to
    // return to a known good state.
    public func handleFailedCurrentCall(error: CallError) {
        Logger.debug("\(self.logTag) in \(#function)")

        // Return to a known good state by ending the current call, if any.
        handleFailedCall(failedCall: self.call, error: error)
    }

    // This method should be called when a fatal error occurred for a call.
    //
    // * If we know which call it was, we should update that call's state
    //   to reflect the error.
    // * IFF that call is the current call, we want to terminate it.
    public func handleFailedCall(failedCall: SignalCall?, error: CallError) {
        SwiftAssertIsOnMainThread(#function)

        if case CallError.assertionError(description: let description) = error {
            owsFail(description)
        }

        if let failedCall = failedCall {

            switch failedCall.state {
            case .answering, .localRinging:
                assert(failedCall.callRecord == nil)
                // call failed before any call record could be created, make one now.
                handleMissedCall(failedCall)
            default:
                assert(failedCall.callRecord != nil)
            }
            

            // It's essential to set call.state before terminateCall, because terminateCall nils self.call
            failedCall.error = error
            failedCall.state = .localFailure
            self.callUIAdapter.failCall(failedCall, error: error)

            // Only terminate the current call if the error pertains to the current call.
            guard failedCall == self.call else {
                Logger.debug("\(self.logTag) in \(#function) ignoring obsolete call: \(failedCall.identifiersForLogs).")
                return
            }

            Logger.error("\(self.logTag) call: \(failedCall.identifiersForLogs) failed with error: \(error)")
        } else {
            Logger.error("\(self.logTag) unknown call failed with error: \(error)")
        }

        // Only terminate the call if it is the current call.
        terminateCall()
    }

    /**
     * Clean up any existing call state and get ready to receive a new call.
     */
    private func terminateCall() {
        SwiftAssertIsOnMainThread(#function)

        Logger.debug("\(self.logTag) in \(#function)")

        let currentCallData = self.callData
        self.callData = nil

        currentCallData?.terminate()

        self.callUIAdapter.didTerminateCall(self.call)

        fireDidUpdateVideoTracks()
    }

    // MARK: - CallObserver

    internal func stateDidChange(call: SignalCall, state: CallState) {
        SwiftAssertIsOnMainThread(#function)
        Logger.info("\(self.logTag) \(#function): \(state)")
        updateIsVideoEnabled()
    }

    internal func hasLocalVideoDidChange(call: SignalCall, hasLocalVideo: Bool) {
        SwiftAssertIsOnMainThread(#function)
        Logger.info("\(self.logTag) \(#function): \(hasLocalVideo)")
        self.updateIsVideoEnabled()
    }

    internal func muteDidChange(call: SignalCall, isMuted: Bool) {
        SwiftAssertIsOnMainThread(#function)
        // Do nothing
    }

    internal func holdDidChange(call: SignalCall, isOnHold: Bool) {
        SwiftAssertIsOnMainThread(#function)
        // Do nothing
    }

    internal func audioSourceDidChange(call: SignalCall, audioSource: AudioSource?) {
        SwiftAssertIsOnMainThread(#function)
        // Do nothing
    }

    // MARK: - Video

    private func shouldHaveLocalVideoTrack() -> Bool {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            return false
        }

        // The iOS simulator doesn't provide any sort of camera capture
        // support or emulation (http://goo.gl/rHAnC1) so don't bother
        // trying to open a local stream.
        return (!Platform.isSimulator &&
            UIApplication.shared.applicationState != .background &&
            call.state == .connected &&
            call.hasLocalVideo)
    }

    //TODO only fire this when it's changed? as of right now it gets called whenever you e.g. lock the phone while it's incoming ringing.
    private func updateIsVideoEnabled() {
        SwiftAssertIsOnMainThread(#function)

        guard let call = self.call else {
            return
        }
        guard let peerConnectionClient = self.peerConnectionClient else {
            return
        }

        let shouldHaveLocalVideoTrack = self.shouldHaveLocalVideoTrack()

        Logger.info("\(self.logTag) \(#function): \(shouldHaveLocalVideoTrack)")

        self.peerConnectionClient?.setLocalVideoEnabled(enabled: shouldHaveLocalVideoTrack)

        let message = DataChannelMessage.forVideoStreamingStatus(callId: call.signalingId, enabled: shouldHaveLocalVideoTrack)
        peerConnectionClient.sendDataChannelMessage(data: message.asData(), description: "videoStreamingStatus", isCritical: false)
    }

    // MARK: - Observers

    // The observer-related methods should be invoked on the main thread.
    func addObserverAndSyncState(observer: CallServiceObserver) {
        SwiftAssertIsOnMainThread(#function)

        observers.append(Weak(value: observer))

        // Synchronize observer with current call state
        let call = self.call
        let localVideoTrack = self.localVideoTrack
        let remoteVideoTrack = self.isRemoteVideoEnabled ? self.remoteVideoTrack : nil
        observer.didUpdateVideoTracks(call: call,
                                      localVideoTrack: localVideoTrack,
                                      remoteVideoTrack: remoteVideoTrack)
    }

    // The observer-related methods should be invoked on the main thread.
    func removeObserver(_ observer: CallServiceObserver) {
        SwiftAssertIsOnMainThread(#function)

        while let index = observers.index(where: { $0.value === observer }) {
            observers.remove(at: index)
        }
    }

    // The observer-related methods should be invoked on the main thread.
    func removeAllObservers() {
        SwiftAssertIsOnMainThread(#function)

        observers = []
    }

    private func fireDidUpdateVideoTracks() {
        SwiftAssertIsOnMainThread(#function)

        let call = self.call
        let localVideoTrack = self.localVideoTrack
        let remoteVideoTrack = self.isRemoteVideoEnabled ? self.remoteVideoTrack : nil

        for observer in observers {
            observer.value?.didUpdateVideoTracks(call: call,
                                                 localVideoTrack: localVideoTrack,
                                                 remoteVideoTrack: remoteVideoTrack)
        }
    }

    // MARK: CallViewController Timer

    var activeCallTimer: Timer?
    func startCallTimer() {
        SwiftAssertIsOnMainThread(#function)

        if self.activeCallTimer != nil {
            owsFail("\(self.logTag) activeCallTimer should only be set once per call")
            self.activeCallTimer!.invalidate()
            self.activeCallTimer = nil
        }

        self.activeCallTimer = WeakTimer.scheduledTimer(timeInterval: 1, target: self, userInfo: nil, repeats: true) { [weak self] timer in
            guard let strongSelf = self else {
                return
            }

            guard let call = strongSelf.call else {
                owsFail("\(strongSelf.logTag) call has since ended. Timer should have been invalidated.")
                timer.invalidate()
                return
            }

            strongSelf.ensureCallScreenPresented(call: call)
        }
    }

    func ensureCallScreenPresented(call: SignalCall) {
        guard let connectedDate = call.connectedDate else {
            // Ignore; call hasn't connected yet.
            return
        }

        let kMaxViewPresentationDelay: Double = 5
        guard fabs(connectedDate.timeIntervalSinceNow) > kMaxViewPresentationDelay else {
            // Ignore; call connected recently.
            return
        }

        if !OWSWindowManager.shared().hasCall() {
            OWSProdError(OWSAnalyticsEvents.callServiceCallViewCouldNotPresent(), file: #file, function: #function, line: #line)
            owsFail("\(self.logTag) in \(#function) Call terminated due to missing call view.")
            self.handleFailedCall(failedCall: call, error: CallError.assertionError(description: "Call view didn't present after \(kMaxViewPresentationDelay) seconds"))
            return
        }
    }

    func stopAnyCallTimer() {
        SwiftAssertIsOnMainThread(#function)

        self.activeCallTimer?.invalidate()
        self.activeCallTimer = nil
    }
}
