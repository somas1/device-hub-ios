import ComposableArchitecture
import DeviceHubCore

extension RemoteSessionFeature {
    func reduceSelection(
        state: inout State,
        action: Action
    ) -> Effect<Action> {
        switch action {
        case let .availabilitySnapshotReceived(devices):
            return reconcileRoster(
                state: &state,
                devices: devices
            )

        case let .deviceSelected(deviceID):
            guard deviceID != state.selectedDeviceID
                || state.session?.device.id != deviceID
            else {
                return .none
            }
            guard let device = state.roster.devices.first(
                where: { $0.id == deviceID }
            ) else {
                return .none
            }

            state.selectedDeviceID = deviceID
            state.isViewingStopped = false
            state.pairing = nil
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case let .pairedDevicesResponse(result):
            state.isLoadingRoster = false
            switch result {
            case let .success(devices):
                return reconcileRoster(
                    state: &state,
                    devices: devices
                )
            case let .failure(error):
                guard !state.inputCleanupFailed else { return .none }
                state.remediation = DeviceHubRemediation(error: error)
                return .none
            }

        case .retrySelectedDevice:
            guard state.pendingInputCleanup == nil else { return .none }
            let acknowledge = state.inputCleanupFailed
            state.inputCleanupFailed = false
            guard let device = state.selectedDevice else {
                return .none
            }
            let begin = beginSessionIfPossible(state: &state, device: device)
            guard acknowledge else { return begin }
            return .concatenate(.run { [sessionCoordinator] _ in
                await sessionCoordinator.acknowledgeCleanupFailure()
            }, begin)

        case .startViewingButtonTapped:
            guard let device = state.selectedDevice else {
                return .none
            }
            state.isViewingStopped = false
            return beginSessionIfPossible(
                state: &state,
                device: device
            )

        case .stopViewingButtonTapped:
            guard state.selectedDevice != nil else {
                return .none
            }
            let previousSession = state.session
            state.activeContactIDs.removeAll()
            state.isViewingStopped = true
            state.session = nil
            guard let previousSession else {
                return cancelSessionEffects()
            }
            return .concatenate(
                closeSessionEffect(session: previousSession, state: &state),
                cancelSessionEffects()
            )

        default:
            return .none
        }
    }

    func beginSessionIfPossible(
        state: inout State,
        device: DeviceSummary
    ) -> Effect<Action> {
        guard !state.inputCleanupFailed, state.pendingInputCleanup == nil else { return .none }
        let previousSession = state.session
        state.activeContactIDs.removeAll()
        state.isViewingStopped = false
        state.remediation = nil
        state.session = nil
        let mayConnect = state.lifecycle == .active && device.pairingState == .paired
            && device.reachability == .reachable
        if let previousSession {
            return .concatenate(
                closeSessionEffect(session: previousSession, state: &state, resumeViewing: mayConnect),
                cancelSessionEffects()
            )
        }
        guard mayConnect else { return cancelSessionEffects() }

        let attemptID = uuid()
        state.session = ActiveRemoteSession(
            attemptID: attemptID,
            device: device,
            evaluatedAt: date.now
        )
        let connect = connectEffect(
            attemptID: attemptID,
            deviceID: device.id,
            cancelID: .connect
        )
        return .concatenate(cancelSessionEffects(), connect)
    }

    func reconcileRoster(
        state: inout State,
        devices: [DeviceSummary]
    ) -> Effect<Action> {
        let previousSelection = state.selectedDeviceID
        state.roster = DeviceRoster(devices: devices)
        state.selectedDeviceID = state.roster.selectionID(
            preserving: previousSelection
        )
        if state.selectedDeviceID != previousSelection {
            state.isViewingStopped = false
        }

        let deviceUpdate = updateActiveDevice(state: &state)

        guard !state.isViewingStopped,
              state.selectedDeviceID != previousSelection
              || state.session == nil,
              let selectedDevice = state.selectedDevice
        else {
            if state.selectedDeviceID == nil {
                let previousSession = state.session
                state.session = nil
                guard let previousSession else {
                    return cancelSessionEffects()
                }
                return .concatenate(
                    closeSessionEffect(session: previousSession, state: &state),
                    cancelSessionEffects()
                )
            }
            return deviceUpdate
        }

        return .concatenate(
            deviceUpdate,
            beginSessionIfPossible(
                state: &state,
                device: selectedDevice
            )
        )
    }

    private func updateActiveDevice(
        state: inout State
    ) -> Effect<Action> {
        guard var session = state.session,
              let device = state.selectedDevice,
              session.device.id == device.id
        else {
            return .none
        }

        let wasAcceptingInput = session.acceptsInput
        session.device = device
        if var remoteState = session.remoteState {
            _ = remoteState.apply(
                SessionUpdate(
                    generation: remoteState.generation,
                    event: .deviceInfoUpdated(device)
                )
            )
            session.remoteState = remoteState
        }
        state.session = session
        if device.pairingState != .paired {
            session.connectionError = .needsPairing
            state.session = session
            state.remediation = DeviceHubRemediation(error: .needsPairing)
            state.activeContactIDs.removeAll()
            return .concatenate(
                closeSessionEffect(session: session, state: &state),
                cancelSessionEffects()
            )
        }
        guard wasAcceptingInput, !session.acceptsInput else {
            return .none
        }
        DeviceHubFeatureTrace.emit(
            "input_revoked source=availability_update"
        )
        return .concatenate(
            revokeInput(state: &state),
            .cancel(id: CancelID.commands)
        )
    }
}
