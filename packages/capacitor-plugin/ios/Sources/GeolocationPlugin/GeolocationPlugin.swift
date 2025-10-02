import Capacitor
import UIKit
import Combine

#if canImport(IONGeolocationLib)
import IONGeolocationLib

@objc(GeolocationPlugin)
public class GeolocationPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GeolocationPlugin"
    public let jsName = "Geolocation"
    public let pluginMethods: [CAPPluginMethod] = [
        .init(name: "getCurrentPosition", returnType: CAPPluginReturnPromise),
        .init(name: "watchPosition", returnType: CAPPluginReturnCallback),
        .init(name: "clearWatch", returnType: CAPPluginReturnPromise),
        .init(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        .init(name: "requestPermissions", returnType: CAPPluginReturnPromise)
    ]

    private var locationService: (any IONGLOCService)?
    private var cancellables = Set<AnyCancellable>()
    private var locationCancellable: AnyCancellable?
    private var callbackManager: GeolocationCallbackManager?
    private var statusInitialized = false
    private var locationInitialized: Bool = false

    override public func load() {
        self.locationService = IONGLOCManagerWrapper()
        self.callbackManager = .init(capacitorBridge: bridge)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        if let watchCallbacksEmpty = callbackManager?.watchCallbacks.isEmpty, !watchCallbacksEmpty {
            print("App became active. Restarting location monitoring for watch callbacks.")
            locationCancellable?.cancel()
            locationCancellable = nil
            locationInitialized = false
            
            locationService?.stopMonitoringLocation()
            locationService?.startMonitoringLocation()
            bindLocationPublisher()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func getCurrentPosition(_ call: CAPPluginCall) {
        shouldSetupBindings()
        let enableHighAccuracy = call.getBool(Constants.Arguments.enableHighAccuracy, false)
        handleLocationRequest(enableHighAccuracy, call: call)
    }

    @objc func watchPosition(_ call: CAPPluginCall) {
        shouldSetupBindings()
        let enableHighAccuracy = call.getBool(Constants.Arguments.enableHighAccuracy, false)
        let watchUUID = call.callbackId
        handleLocationRequest(enableHighAccuracy, watchUUID: watchUUID, call: call)
    }

    @objc func clearWatch(_ call: CAPPluginCall) {
        shouldSetupBindings()
        guard let callbackId = call.getString(Constants.Arguments.id) else {
            callbackManager?.sendError(.inputArgumentsIssue(target: .clearWatch))
            return
        }
        callbackManager?.clearWatchCallbackIfExists(callbackId)

        if (callbackManager?.watchCallbacks.isEmpty) ?? false {
            locationService?.stopMonitoringLocation()
            locationCancellable?.cancel()
            locationCancellable = nil
            locationInitialized = false
        }

        callbackManager?.sendSuccess(call)
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        guard checkIfLocationServicesAreEnabled(call) else { return }

        let status = switch locationService?.authorisationStatus {
        case .restricted, .denied: Constants.AuthorisationStatus.Status.denied
        case .authorisedAlways, .authorisedWhenInUse: Constants.AuthorisationStatus.Status.granted
        default: Constants.AuthorisationStatus.Status.prompt
        }

        let callResultData = [
            Constants.AuthorisationStatus.ResultKey.location: status,
            Constants.AuthorisationStatus.ResultKey.coarseLocation: status
        ]
        callbackManager?.sendSuccess(call, with: callResultData)
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        guard checkIfLocationServicesAreEnabled(call) else { return }

        if locationService?.authorisationStatus == .notDetermined {
            shouldSetupBindings()
            callbackManager?.addRequestPermissionsCallback(capacitorCall: call)
        } else {
            checkPermissions(call)
        }
    }
}

private extension GeolocationPlugin {
    func shouldSetupBindings() {
        bindAuthorisationStatusPublisher()
        bindLocationPublisher()
    }

    func bindAuthorisationStatusPublisher() {
        guard !statusInitialized else { return }
        statusInitialized = true
        locationService?.authorisationStatusPublisher
            .sink(receiveValue: { [weak self] status in
                guard let self else { return }

                switch status {
                case .denied:
                    self.onLocationPermissionNotGranted(error: .permissionDenied)
                case .notDetermined:
                    self.requestLocationAuthorisation(type: .whenInUse)
                case .restricted:
                    self.onLocationPermissionNotGranted(error: .permissionRestricted)
                case .authorisedAlways, .authorisedWhenInUse:
                    self.onLocationPermissionGranted()
                @unknown default: break
                }
            })
            .store(in: &cancellables)
    }

    func bindLocationPublisher() {
        guard !locationInitialized else { return }
        locationInitialized = true
        locationCancellable = locationService?.currentLocationPublisher
            .catch { [weak self] error -> AnyPublisher<IONGLOCPositionModel, Never> in
                print("An error was found while retrieving the location: \(error)")
                
                if case IONGLOCLocationError.locationUnavailable = error {
                    print("Location unavailable (likely due to backgrounding). Keeping watch callbacks alive.")
                    self?.callbackManager?.sendError(.positionUnavailable)
                    return Empty<IONGLOCPositionModel, Never>()
                        .eraseToAnyPublisher()
                } else {
                    self?.callbackManager?.sendError(.positionUnavailable)
                    return Empty<IONGLOCPositionModel, Never>()
                        .eraseToAnyPublisher()
                }
            }
            .sink(receiveValue: { [weak self] position in
                self?.callbackManager?.sendSuccess(with: position.toJSObject())
            })
    }

    func requestLocationAuthorisation(type requestType: IONGLOCAuthorisationRequestType) {
        DispatchQueue.global(qos: .background).async {
            guard self.checkIfLocationServicesAreEnabled() else { return }
            self.locationService?.requestAuthorisation(withType: requestType)
        }
    }

    func checkIfLocationServicesAreEnabled(_ call: CAPPluginCall? = nil) -> Bool {
        guard locationService?.areLocationServicesEnabled() == true else {
            call.map { callbackManager?.sendError($0, error: .locationServicesDisabled) }
                ?? callbackManager?.sendError(.locationServicesDisabled)
            return false
        }
        return true
    }

    func onLocationPermissionNotGranted(error: GeolocationError) {
        let shouldNotifyRequestPermissionsResult = callbackManager?.requestPermissionsCallbacks.isEmpty == false
        let shouldNotifyPermissionError = callbackManager?.locationCallbacks.isEmpty == false ||  callbackManager?.watchCallbacks.isEmpty == false

        if shouldNotifyRequestPermissionsResult {
            self.callbackManager?.sendRequestPermissionsSuccess(Constants.AuthorisationStatus.Status.denied)
        }
        if shouldNotifyPermissionError {
            self.callbackManager?.sendError(error)
        }
    }

    func onLocationPermissionGranted() {
        let shouldNotifyPermissionGranted = callbackManager?.requestPermissionsCallbacks.isEmpty == false
        // should request location if callbacks below exist and are not empty
        let shouldRequestCurrentPosition = callbackManager?.locationCallbacks.isEmpty == false
        let shouldRequestLocationMonitoring = callbackManager?.watchCallbacks.isEmpty == false

        if shouldNotifyPermissionGranted {
            callbackManager?.sendRequestPermissionsSuccess(Constants.AuthorisationStatus.Status.granted)
        }
        if shouldRequestCurrentPosition {
            locationService?.requestSingleLocation()
        }
        if shouldRequestLocationMonitoring {
            locationService?.startMonitoringLocation()
        }
    }

    func handleLocationRequest(_ enableHighAccuracy: Bool, watchUUID: String? = nil, call: CAPPluginCall) {
        bindLocationPublisher()
        let configurationModel = IONGLOCConfigurationModel(enableHighAccuracy: enableHighAccuracy)
        locationService?.updateConfiguration(configurationModel)

        if let watchUUID {
            callbackManager?.addWatchCallback(watchUUID, capacitorCall: call)
        } else {
            callbackManager?.addLocationCallback(capacitorCall: call)
        }

        switch locationService?.authorisationStatus {
        case .authorisedAlways, .authorisedWhenInUse: onLocationPermissionGranted()
        case .denied: callbackManager?.sendError(.permissionDenied)
        case .restricted: callbackManager?.sendError(.permissionRestricted)
        default: break
        }
    }
}

#else

import CoreLocation

@objc(GeolocationPlugin)
public class GeolocationPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GeolocationPlugin"
    public let jsName = "Geolocation"
    public let pluginMethods: [CAPPluginMethod] = [
        .init(name: "getCurrentPosition", returnType: CAPPluginReturnPromise),
        .init(name: "watchPosition", returnType: CAPPluginReturnCallback),
        .init(name: "clearWatch", returnType: CAPPluginReturnPromise),
        .init(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        .init(name: "requestPermissions", returnType: CAPPluginReturnPromise)
    ]

    private let locationManager = CLLocationManager()
    private var callbackManager: GeolocationCallbackManager?
    private var isWatching = false

    override public func load() {
        locationManager.delegate = self
        callbackManager = .init(capacitorBridge: bridge)
    }

    @objc func getCurrentPosition(_ call: CAPPluginCall) {
        callbackManager?.addLocationCallback(capacitorCall: call)
        requestLocationIfAuthorized()
    }

    @objc func watchPosition(_ call: CAPPluginCall) {
        isWatching = true
        callbackManager?.addWatchCallback(call.callbackId, capacitorCall: call)
        requestLocationIfAuthorized(startUpdating: true)
    }

    @objc func clearWatch(_ call: CAPPluginCall) {
        guard let callbackId = call.getString(Constants.Arguments.id) else {
            callbackManager?.sendError(.inputArgumentsIssue(target: .clearWatch))
            return
        }
        callbackManager?.clearWatchCallbackIfExists(callbackId)
        if callbackManager?.watchCallbacks.isEmpty == true {
            isWatching = false
            locationManager.stopUpdatingLocation()
        }
        callbackManager?.sendSuccess(call)
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        let status = mapAuthStatus(CLLocationManager.authorizationStatus())
        let result = [
            Constants.AuthorisationStatus.ResultKey.location: status,
            Constants.AuthorisationStatus.ResultKey.coarseLocation: status
        ]
        callbackManager?.sendSuccess(call, with: result)
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            callbackManager?.addRequestPermissionsCallback(capacitorCall: call)
            locationManager.requestWhenInUseAuthorization()
        default:
            checkPermissions(call)
        }
    }

    private func mapAuthStatus(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedWhenInUse, .authorized: return Constants.AuthorisationStatus.Status.granted
        case .denied, .restricted: return Constants.AuthorisationStatus.Status.denied
        case .notDetermined: fallthrough
        @unknown default: return Constants.AuthorisationStatus.Status.prompt
        }
    }

    private func requestLocationIfAuthorized(startUpdating: Bool = false) {
        switch CLLocationManager.authorizationStatus() {
        case .authorizedWhenInUse, .authorized:
            if startUpdating {
                locationManager.startUpdatingLocation()
            } else {
                locationManager.requestLocation()
            }
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied:
            callbackManager?.sendError(.permissionDenied)
        case .restricted:
            callbackManager?.sendError(.permissionRestricted)
        @unknown default:
            break
        }
    }
}

extension GeolocationPlugin: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorized:
            if callbackManager?.requestPermissionsCallbacks.isEmpty == false {
                callbackManager?.sendRequestPermissionsSuccess(Constants.AuthorisationStatus.Status.granted)
            }
            if isWatching {
                manager.startUpdatingLocation()
            } else {
                manager.requestLocation()
            }
        case .denied:
            if callbackManager?.requestPermissionsCallbacks.isEmpty == false {
                callbackManager?.sendRequestPermissionsSuccess(Constants.AuthorisationStatus.Status.denied)
            }
            callbackManager?.sendError(.permissionDenied)
        case .restricted:
            if callbackManager?.requestPermissionsCallbacks.isEmpty == false {
                callbackManager?.sendRequestPermissionsSuccess(Constants.AuthorisationStatus.Status.denied)
            }
            callbackManager?.sendError(.permissionRestricted)
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let jsObject: JSObject = [
            Constants.Position.timestamp: location.timestamp.timeIntervalSince1970 * 1000,
            Constants.Position.coords: [
                Constants.Position.latitude: location.coordinate.latitude,
                Constants.Position.longitude: location.coordinate.longitude,
                Constants.Position.accuracy: location.horizontalAccuracy,
                Constants.Position.altitude: location.altitude,
                Constants.Position.altitudeAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : 0,
                Constants.Position.speed: location.speed,
                Constants.Position.heading: location.course
            ]
        ]
        callbackManager?.sendSuccess(with: jsObject)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        callbackManager?.sendError(.positionUnavailable)
    }
}

#endif
