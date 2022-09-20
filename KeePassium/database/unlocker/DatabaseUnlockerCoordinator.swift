//  KeePassium Password Manager
//  Copyright © 2018–2022 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import KeePassiumLib

typealias DatabaseUnlockResult = Result<Database, Error>

protocol DatabaseUnlockerCoordinatorDelegate: AnyObject {
    func shouldDismissFromKeyboard(_ coordinator: DatabaseUnlockerCoordinator) -> Bool
    
    func shouldAutoUnlockDatabase(
        _ fileRef: URLReference,
        in coordinator: DatabaseUnlockerCoordinator
    ) -> Bool
    func willUnlockDatabase(_ fileRef: URLReference, in coordinator: DatabaseUnlockerCoordinator)
    func didNotUnlockDatabase(
        _ fileRef: URLReference,
        with message: String?,
        reason: String?,
        in coordinator: DatabaseUnlockerCoordinator
    )
    
    func shouldChooseFallbackStrategy(
        for fileRef: URLReference,
        in coordinator: DatabaseUnlockerCoordinator
    ) -> UnreachableFileFallbackStrategy
    
    func didUnlockDatabase(
        databaseFile: DatabaseFile,
        at fileRef: URLReference,
        warnings: DatabaseLoadingWarnings,
        in coordinator: DatabaseUnlockerCoordinator
    )
    func didPressReinstateDatabase(_ fileRef: URLReference, in coordinator: DatabaseUnlockerCoordinator)
}

final class DatabaseUnlockerCoordinator: Coordinator, Refreshable {
    enum State {
        case unlockOriginalFileFast
        case unlockOriginalFileSlow
        case unlockFallbackFile
    }
    var childCoordinators = [Coordinator]()
    var dismissHandler: CoordinatorDismissHandler?
    weak var delegate: DatabaseUnlockerCoordinatorDelegate?
    
    private let router: NavigationRouter
    private let databaseUnlockerVC: DatabaseUnlockerVC
    
    private var databaseRef: URLReference
    private var fallbackDatabaseRef: URLReference?
    private var selectedKeyFileRef: URLReference?
    private var selectedHardwareKey: YubiKey?
    
    private var state: State = .unlockOriginalFileFast
    private var databaseLoader: DatabaseLoader?
    
    init(router: NavigationRouter, databaseRef: URLReference) {
        self.router = router
        self.databaseRef = databaseRef
        self.fallbackDatabaseRef = DatabaseManager.getFallbackFile(for: databaseRef)

        databaseUnlockerVC = DatabaseUnlockerVC.instantiateFromStoryboard()
        databaseUnlockerVC.delegate = self
        databaseUnlockerVC.shouldAutofocus = true
        databaseUnlockerVC.databaseRef = databaseRef
    }
    
    deinit {
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
    }
    
    func start() {
        router.push(databaseUnlockerVC, animated: true, onPop: { [weak self] in
            guard let self = self else { return }
            self.removeAllChildCoordinators()
            self.dismissHandler?(self)
        })
    }
    
    func refresh() {
        databaseUnlockerVC.refresh()
    }
    
    func cancelLoading(reason: ProgressEx.CancellationReason) {
        databaseLoader?.cancel(reason: reason)
    }
    
    func setDatabase(_ fileRef: URLReference) {
        databaseRef = fileRef
        databaseUnlockerVC.databaseRef = fileRef
        
        guard let dbSettings = DatabaseSettingsManager.shared.getSettings(for: databaseRef) else {
            setKeyFile(nil)
            setHardwareKey(nil)
            state = .unlockOriginalFileSlow
            refresh()
            return
        }
        
        if let associatedKeyFileRef = dbSettings.associatedKeyFile {
            let allKeyFiles = FileKeeper.shared.getAllReferences(
                fileType: .keyFile,
                includeBackup: false)
            let matchingKeyFile = associatedKeyFileRef.find(
                in: allKeyFiles,
                fallbackToNamesake: true)
            setKeyFile(matchingKeyFile) 
        } else {
            setKeyFile(nil)
        }

        let associatedYubiKey = dbSettings.associatedYubiKey
        setHardwareKey(associatedYubiKey) 
        
        state = .unlockOriginalFileFast
        refresh()
        
        DispatchQueue.main.async { [self] in
            maybeShowInitialDatabaseError(fileRef)
        }
    }
    
    private func maybeShowInitialDatabaseError(_ fileRef: URLReference) {
        databaseUnlockerVC.hideErrorMessage(animated: false)
        if let dbError = fileRef.error {
            showDatabaseError(fileRef.visibleFileName, reason: dbError.localizedDescription)
            return
        }
        
        fileRef.refreshInfo(timeout: 2) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(_):
                self.refresh()
            case .failure(let fileAccessError):
                if fileAccessError.isTimeout {
                    return
                }
                self.showDatabaseError(
                    self.databaseRef.visibleFileName,
                    reason: fileAccessError.localizedDescription
                )
            }
        }
    }
}

extension DatabaseUnlockerCoordinator {
    private func showDiagnostics(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let modalRouter = NavigationRouter.createModal(style: .formSheet, at: popoverAnchor)
        let diagnosticsViewerCoordinator = DiagnosticsViewerCoordinator(router: modalRouter)
        diagnosticsViewerCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        diagnosticsViewerCoordinator.start()
        viewController.present(modalRouter, animated: true, completion: nil)
        addChildCoordinator(diagnosticsViewerCoordinator)
    }
    
    private func getPopoverRouter(at popoverAnchor: PopoverAnchor) -> NavigationRouter {
        #if AUTOFILL_EXT
        if ProcessInfo.isRunningOnMac {
            return router
        }
        #endif
        return NavigationRouter.createModal(style: .popover, at: popoverAnchor)
    }
    
    private func selectKeyFile(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let targetRouter = getPopoverRouter(at: popoverAnchor)
        let keyFilePickerCoordinator = KeyFilePickerCoordinator(router: targetRouter)
        keyFilePickerCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        keyFilePickerCoordinator.delegate = self
        keyFilePickerCoordinator.start()
        addChildCoordinator(keyFilePickerCoordinator)
        if targetRouter != router {
            viewController.present(targetRouter, animated: true, completion: nil)
        }
    }
    
    private func selectHardwareKey(
        at popoverAnchor: PopoverAnchor,
        in viewController: UIViewController
    ) {
        let targetRouter = getPopoverRouter(at: popoverAnchor)
        let hardwareKeyPickerCoordinator = HardwareKeyPickerCoordinator(router: targetRouter)
        hardwareKeyPickerCoordinator.dismissHandler = { [weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
        }
        hardwareKeyPickerCoordinator.delegate = self
        hardwareKeyPickerCoordinator.setSelectedKey(selectedHardwareKey)
        hardwareKeyPickerCoordinator.start()
        addChildCoordinator(hardwareKeyPickerCoordinator)
        if targetRouter != router {
            viewController.present(targetRouter, animated: true, completion: nil)
        }
    }
    
    private func setKeyFile(_ fileRef: URLReference?) {
        selectedKeyFileRef = fileRef
        DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
            dbSettings.maybeSetAssociatedKeyFile(fileRef)
        }
        
        databaseUnlockerVC.setKeyFile(fileRef)
        databaseUnlockerVC.refresh()
    }
    
    private func setHardwareKey(_ yubiKey: YubiKey?) {
        selectedHardwareKey = yubiKey
        DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
            dbSettings.maybeSetAssociatedYubiKey(yubiKey)
        }
        databaseUnlockerVC.setYubiKey(yubiKey)
        databaseUnlockerVC.refresh()
    }
    
    #if AUTOFILL_EXT
    private func challengeHandlerForAutoFill(
        challenge: SecureBytes,
        responseHandler: @escaping ResponseHandler
    ) {
        Diag.warning("YubiKey is not available in AutoFill")
        responseHandler(SecureBytes.empty(), .notAvailableInAutoFill)
    }
    #endif
    
    private func canUnlockAutomatically() -> Bool {
        guard let dbSettings = DatabaseSettingsManager.shared.getSettings(for: databaseRef) else {
            return false
        }
        return dbSettings.hasMasterKey
    }
    
    private func maybeUnlockAutomatically() {
        guard canUnlockAutomatically() else {
            return
        }
        guard delegate?.shouldAutoUnlockDatabase(databaseRef, in: self) ?? false else {
            return
        }
        databaseUnlockerVC.showProgressView(
            title: LString.databaseStatusLoading,
            allowCancelling: true,
            animated: false)
        
        tryToUnlockDatabase()
    }

    private func tryToUnlockDatabase() {
        Diag.clear()

        delegate?.willUnlockDatabase(databaseRef, in: self)
        databaseUnlockerVC.hideErrorMessage(animated: false)
        retryToUnlockDatabase()
    }
    
    private func retryToUnlockDatabase() {
        assert(databaseLoader == nil)
        
        #if AUTOFILL_EXT
        let challengeHandler = (selectedHardwareKey != nil) ? challengeHandlerForAutoFill : nil
        #elseif MAIN_APP
        let challengeHandler = ChallengeResponseManager.makeHandler(for: selectedHardwareKey)
        #endif
        
        let databaseSettingsManager = DatabaseSettingsManager.shared
        let dbSettings = databaseSettingsManager.getSettings(for: databaseRef)
        let compositeKey: CompositeKey
        if let storedCompositeKey = dbSettings?.masterKey {
            compositeKey = storedCompositeKey
            compositeKey.challengeHandler = challengeHandler
            if state == .unlockOriginalFileSlow {
                compositeKey.eraseFinalKeys()
            }
        } else {
            if state == .unlockOriginalFileFast {
                state = .unlockOriginalFileSlow
            }
            let password = databaseUnlockerVC.password
            compositeKey = CompositeKey(
                password: password,
                keyFileRef: selectedKeyFileRef,
                challengeHandler: challengeHandler
            )
        }

        var databaseStatus = DatabaseFile.Status()
        let currentDatabaseRef: URLReference
        switch state {
        case .unlockOriginalFileFast,
             .unlockOriginalFileSlow:
            currentDatabaseRef = databaseRef
        case .unlockFallbackFile:
            guard let fallbackDatabaseRef = fallbackDatabaseRef else {
                assertionFailure("Tried to open non-existent database")
                return
            }
            currentDatabaseRef = fallbackDatabaseRef
            databaseStatus.insert(.localFallback)
        }
        
        if databaseSettingsManager.isReadOnly(currentDatabaseRef) {
            databaseStatus.insert(.readOnly)
        }
        let fallbackTimeout = databaseSettingsManager.getFallbackTimeout(currentDatabaseRef)

        databaseLoader = DatabaseLoader(
            dbRef: currentDatabaseRef,
            compositeKey: compositeKey,
            status: databaseStatus,
            timeout: fallbackTimeout,
            delegate: self
        )
        databaseLoader!.load()
    }
    
    private func eraseMasterKey() {
        DatabaseSettingsManager.shared.updateSettings(for: databaseRef) {
            $0.clearMasterKey()
        }
    }
    
    private func showDatabaseError(_ message: String, reason: String?) {
        guard databaseRef.needsReinstatement else {
            databaseUnlockerVC.showErrorMessage(message, reason: reason, haptics: .error)
            return
        }
        databaseUnlockerVC.showErrorMessage(
            message,
            reason: reason,
            haptics: .error,
            action: ToastAction(
                title: LString.actionReAddFile,
                icon: nil,
                handler: { [weak self] in
                    guard let self = self else { return }
                    Diag.debug("Will reinstate database")
                    self.delegate?.didPressReinstateDatabase(self.databaseRef, in: self)
                }
            )
        )
    }
}

extension DatabaseUnlockerCoordinator: DatabaseUnlockerDelegate {
    func shouldDismissFromKeyboard(_ viewController: DatabaseUnlockerVC) -> Bool {
        return delegate?.shouldDismissFromKeyboard(self) ?? false
    }

    func willAppear(viewController: DatabaseUnlockerVC) {
        maybeUnlockAutomatically()
    }
    
    func didPressSelectKeyFile(
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabaseUnlockerVC
    ) {
        router.dismissModals(animated: false, completion: { [weak self] in
            self?.selectKeyFile(at: popoverAnchor, in: viewController)
        })
    }
    
    func didPressSelectHardwareKey(
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabaseUnlockerVC
    ) {
        router.dismissModals(animated: false, completion: { [weak self] in
            self?.selectHardwareKey(at: popoverAnchor, in: viewController)
        })
    }
    
    func shouldDismissPopovers(in viewController: DatabaseUnlockerVC) {
        router.dismissModals(animated: false, completion: nil)
    }
    

    func canUnlockAutomatically(_ viewController: DatabaseUnlockerVC) -> Bool {
        return canUnlockAutomatically()
    }
    func didPressUnlock(in viewController: DatabaseUnlockerVC) {
        tryToUnlockDatabase()
    }

    func didPressLock(in viewController: DatabaseUnlockerVC) {
        eraseMasterKey()
    }
    
    func didPressShowDiagnostics(
        at popoverAnchor: PopoverAnchor,
        in viewController: DatabaseUnlockerVC
    ) {
        showDiagnostics(at: popoverAnchor, in: viewController)
    }
}

extension DatabaseUnlockerCoordinator: KeyFilePickerCoordinatorDelegate {
    func didPickKeyFile(_ keyFile: URLReference?, in coordinator: KeyFilePickerCoordinator) {
        databaseUnlockerVC.hideErrorMessage(animated: false)
        setKeyFile(keyFile)
    }
    
    func didEliminateKeyFile(_ keyFile: URLReference, in coordinator: KeyFilePickerCoordinator) {
        if keyFile == selectedKeyFileRef {
            databaseUnlockerVC.hideErrorMessage(animated: false)
            setKeyFile(nil)
        }
        databaseUnlockerVC.refresh()
    }
}

extension DatabaseUnlockerCoordinator: HardwareKeyPickerCoordinatorDelegate {
    func didSelectKey(_ yubiKey: YubiKey?, in coordinator: HardwareKeyPickerCoordinator) {
        databaseUnlockerVC.hideErrorMessage(animated: false)
        setHardwareKey(yubiKey)
    }
}

extension DatabaseUnlockerCoordinator: DatabaseLoaderDelegate {
    func databaseLoader(_ databaseLoader: DatabaseLoader, willLoadDatabase dbRef: URLReference) {
        databaseUnlockerVC.showProgressView(
            title: LString.databaseStatusLoading,
            allowCancelling: true,
            animated: true
        )
    }
    
    func databaseLoader(
        _ databaseLoader: DatabaseLoader,
        didChangeProgress progress: ProgressEx,
        for dbRef: URLReference
    ) {
        databaseUnlockerVC.updateProgressView(with: progress)
    }
    
    func databaseLoader(
        _ databaseLoader: DatabaseLoader,
        didFailLoading dbRef: URLReference,
        with error: DatabaseLoader.Error
    ) {
        self.databaseLoader = nil
        switch error {
        case .cancelledByUser:
            DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                dbSettings.clearMasterKey()
            }
            databaseUnlockerVC.refresh()
            databaseUnlockerVC.clearPasswordField()
            databaseUnlockerVC.hideProgressView(animated: true)
            
            databaseUnlockerVC.maybeFocusOnPassword()
        case .invalidKey(_):
            switch state {
            case .unlockOriginalFileFast:
                Diag.info("Express unlock failed, retrying slow")
                state = .unlockOriginalFileSlow
                retryToUnlockDatabase()
                return
            case .unlockOriginalFileSlow,
                 .unlockFallbackFile:
                DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
                    dbSettings.clearMasterKey()
                }
                databaseUnlockerVC.refresh()
                databaseUnlockerVC.hideProgressView(animated: false)
                databaseUnlockerVC.showMasterKeyInvalid(message: error.localizedDescription)
            }
        case .databaseUnreachable(_):
            databaseUnlockerVC.refresh()
            
            let currentDatabaseRef = dbRef 
            let fallbackStrategy: UnreachableFileFallbackStrategy =
                delegate?.shouldChooseFallbackStrategy(for: currentDatabaseRef, in: self)
                ?? .showError
            switch fallbackStrategy {
            case .useCache:
                if fallbackDatabaseRef != nil {
                    Diag.info("Original file unreachable, will try fallback")
                    assert(state != .unlockFallbackFile, "Should not fall back from a fallback file")
                    state = .unlockFallbackFile
                    retryToUnlockDatabase()
                    return
                } else {
                    Diag.info("Original file unreachable and there is no fallback")
                    fallthrough
                }
            case .showError:
                databaseUnlockerVC.hideProgressView(animated: true)
                showDatabaseError(error.localizedDescription, reason: error.failureReason)
                databaseUnlockerVC.maybeFocusOnPassword()
            }
        default:
            databaseUnlockerVC.refresh()
            databaseUnlockerVC.hideProgressView(animated: true)
            
            showDatabaseError(error.localizedDescription, reason: error.failureReason)
            databaseUnlockerVC.maybeFocusOnPassword()
        }
        delegate?.didNotUnlockDatabase(
            databaseRef,
            with: error.localizedDescription,
            reason: error.failureReason,
            in: self
        )
    }
    
    func databaseLoader(
        _ databaseLoader: DatabaseLoader,
        didLoadDatabase dbRef: URLReference,
        databaseFile: DatabaseFile,
        withWarnings warnings: DatabaseLoadingWarnings
    ) {
        self.databaseLoader = nil
        HapticFeedback.play(.databaseUnlocked)

        DatabaseSettingsManager.shared.updateSettings(for: databaseRef) { dbSettings in
            dbSettings.maybeSetMasterKey(of: databaseFile.database)
        }
        databaseUnlockerVC.clearPasswordField()
        
        delegate?.didUnlockDatabase(
            databaseFile: databaseFile,
            at: databaseRef,
            warnings: warnings,
            in: self
        )
    }
}
