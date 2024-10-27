import SwiftUI
import Network
import Foundation
import Combine

// MARK: - Models

/// Represents a Train with an ID and a name.
struct Train: Identifiable, Hashable, Equatable {
    let id: Int
    let name: String
}

/// Represents a Function of a Train with an ID and a Boolean value.
struct TrainFunction: Identifiable {
    let id: Int
    var value: Bool
}

// MARK: - Controller

/// Manages network communication and business logic for the Railroad app.
class RailroadController: ObservableObject {
    // Published properties to update the UI
    @Published var trains: [Train] = []
    @Published var selectedTrain: Train?
    @Published var status: String = ""
    @Published var speedValue: Double = 0.0
    @Published var direction: String = "Forward"
    @Published var functions: [TrainFunction] = []
    @Published var trainsStopped: Bool = false

    private let ip: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "RailroadControllerQueue")
    private var currentCompletionHandler: ((String?) -> Void)?
    private var receiveBuffer = ""
    private var cancellables = Set<AnyCancellable>()

    /// Initializes the controller with the given IP and port.
    init(ip: String, port: UInt16 = 15471) {
        self.ip = ip
        self.port = port
        connect()
    }

    deinit {
        close()
    }

    // MARK: - Network Connection Methods

    /// Establishes a TCP connection to the controller.
    private func connect() {
        let host = NWEndpoint.Host(ip)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        connection = NWConnection(host: host, port: nwPort, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                print("Connected to \(self?.ip ?? ""):\(self?.port ?? 0)")
                self?.receive()
            case .failed(let error):
                print("Connection failed: \(error)")
                self?.connection = nil
                self?.scheduleReconnect()
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    /// Schedules a reconnection attempt after a delay.
    private func scheduleReconnect() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connect()
        }
    }

    /// Continuously receives data from the controller.
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty, let decodedData = String(data: data, encoding: .utf8) {
                self?.processReceivedData(decodedData)
            }
            if error == nil && !isComplete {
                self?.receive()
            } else {
                print("Receive failed: \(String(describing: error))")
                self?.connection = nil
                self?.scheduleReconnect()
            }
        }
    }

    /// Processes the received data, handling responses and events.
    private func processReceivedData(_ data: String) {
        receiveBuffer += data
        if receiveBuffer.contains("<END") {
            let response = receiveBuffer
            receiveBuffer = ""
            DispatchQueue.main.async { [weak self] in
                self?.currentCompletionHandler?(response)
                self?.currentCompletionHandler = nil
            }
        } else if data.contains("<EVENT") {
            processEvent(data)
        }
    }

    /// Processes event messages from the controller.
    private func processEvent(_ data: String) {
        let lines = data.split(separator: "\n")
        for line in lines where line.starts(with: "<EVENT") {
            let eventDescription = line.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            print("Received EVENT: \(eventDescription)")
            // Handle event if needed
        }
    }

    /// Sends a command to the controller and returns a Future with the response.
    func sendCommand(_ command: String) -> Future<String?, Never> {
        return Future { [weak self] promise in
            guard let self = self else {
                promise(.success(nil))
                return
            }
            if self.connection == nil {
                self.connect()
            }
            self.currentCompletionHandler = { response in
                promise(.success(response))
            }
            let message = command + "\n"
            if let data = message.data(using: .utf8) {
                self.connection?.send(content: data, completion: .contentProcessed({ error in
                    if let error = error {
                        print("Send failed: \(error)")
                        self.connection = nil
                        promise(.success(nil))
                    }
                }))
            } else {
                promise(.success(nil))
            }
        }
    }

    // MARK: - Train Management Methods

    /// Refreshes the list of trains by querying the controller.
    func refreshTrains() {
        sendCommand("queryObjects(10, name)")
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                if let response = response {
                    print("Response from controller: \(response)")
                    self?.parseAndDisplayTrains(response)
                } else {
                    self?.logStatus("Failed to retrieve trains.")
                }
            }
            .store(in: &cancellables)
    }

    /// Parses the controller's response and updates the list of trains.
    private func parseAndDisplayTrains(_ response: String) {
        print("parseAndDisplayTrains called with response:\n\(response)")
        var trainsList: [Train] = []

        // Normalize line endings to handle \r\n and \r
        let normalizedResponse = response.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedResponse.components(separatedBy: "\n")

        print("Lines array: \(lines)") // Debugging output

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty {
                continue
            }
            print("Processing line: '\(trimmedLine)'") // Debugging output
            if trimmedLine.starts(with: "<END") || trimmedLine.starts(with: "<REPLY") {
                print("Skipping line: '\(trimmedLine)'") // Debugging output
                continue
            }
            let parts = trimmedLine.split(separator: " ", maxSplits: 1)
            if parts.count == 2 {
                let trainIdString = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                if let trainId = Int(trainIdString) {
                    let namePart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    print("Parsed trainId: \(trainId), namePart: '\(namePart)'") // Debugging output
                    // Extract the name from namePart
                    var name = ""
                    if let nameStartIndex = namePart.firstIndex(of: "\""),
                       let nameEndIndex = namePart.lastIndex(of: "\""),
                       nameStartIndex < nameEndIndex {
                        let nameRange = namePart.index(after: nameStartIndex)..<nameEndIndex
                        name = String(namePart[nameRange])
                    } else {
                        // Handle cases where name is not enclosed in quotes
                        name = String(namePart)
                    }
                    print("Extracted name: '\(name)'") // Debugging output
                    trainsList.append(Train(id: trainId, name: name))
                } else {
                    print("Failed to parse trainId from '\(parts[0])'") // Debugging output
                }
            } else {
                print("Unexpected line format: '\(trimmedLine)'") // Debugging output
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.trains = trainsList
            self?.logStatus("Trains list updated.")
            print("Updated trains array with \(trainsList.count) trains.") // Debugging output
        }
    }

    /// Handles the selection of a train.
    func onTrainSelect(train: Train) {
        logStatus("Selected Train ID: \(train.id)")
        loadTrainFunctions()
    }

    /// Loads the functions for the selected train.
    private func loadTrainFunctions() {
        guard let trainId = selectedTrain?.id else { return }
        sendCommand("get(\(trainId), func)")
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                if let response = response {
                    print("Response from controller (functions):\n\(response)") // Debugging output
                    self?.parseAndDisplayFunctions(response, for: trainId)
                } else {
                    self?.logStatus("Failed to retrieve function settings for Train ID: \(trainId).")
                }
            }
            .store(in: &cancellables)
    }

    /// Parses the controller's response and updates the list of functions for a train.
    private func parseAndDisplayFunctions(_ response: String, for trainId: Int) {
        print("parseAndDisplayFunctions called with response:\n\(response)")
        var functionList: [TrainFunction] = []

        // Normalize line endings
        let normalizedResponse = response.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedResponse.components(separatedBy: "\n")

        print("Functions Lines array: \(lines)") // Debugging output

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty {
                continue
            }
            print("Processing function line: '\(trimmedLine)'") // Debugging output
            if trimmedLine.starts(with: "<END") || trimmedLine.starts(with: "<REPLY") {
                print("Skipping line: '\(trimmedLine)'") // Debugging output
                continue
            }

            // Expected line format: func[funcId, value]
            if let funcStartIndex = trimmedLine.firstIndex(of: "["),
               let funcEndIndex = trimmedLine.lastIndex(of: "]"),
               funcStartIndex < funcEndIndex {
                let funcContent = trimmedLine[trimmedLine.index(after: funcStartIndex)..<funcEndIndex]
                let funcParts = funcContent.split(separator: ",")
                if funcParts.count == 2,
                   let funcId = Int(funcParts[0].trimmingCharacters(in: .whitespaces)),
                   let value = Int(funcParts[1].trimmingCharacters(in: .whitespaces)) {
                    let function = TrainFunction(id: funcId, value: value != 0)
                    functionList.append(function)
                    print("Parsed function: ID=\(funcId), value=\(value)") // Debugging output
                } else {
                    print("Failed to parse function parts: '\(funcContent)'") // Debugging output
                }
            } else {
                print("Invalid function line format: '\(trimmedLine)'") // Debugging output
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.functions = functionList.sorted { $0.id < $1.id }
            self?.logStatus("Loaded \(functionList.count) functions for Train ID: \(trainId)")
            print("Loaded \(functionList.count) functions for Train ID: \(trainId)") // Debugging output
        }
    }

    // MARK: - Control Methods

    /// Toggles a specific function for the selected train.
    func toggleFunction(function: TrainFunction) {
        guard let trainId = selectedTrain?.id else {
            logStatus("Please select a train to control.")
            return
        }
        let intValue = function.value ? 1 : 0
        setFunction(trainId: trainId, funcId: function.id, value: intValue)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                if response != nil {
                    self?.logStatus("Set function \(function.id) to \(intValue) for Train ID: \(trainId)")
                } else {
                    self?.logStatus("Failed to set function \(function.id) for Train ID: \(trainId)")
                }
            }
            .store(in: &cancellables)
    }

    /// Sets a specific function for a train.
    private func setFunction(trainId: Int, funcId: Int, value: Int) -> Future<String?, Never> {
        let command = "set(\(trainId), func[\(funcId), \(value)])"
        return sendCommand(command)
    }

    /// Applies the speed setting to the selected train.
    func applySpeed() {
        guard let trainId = selectedTrain?.id else {
            logStatus("Please select a train to control.")
            return
        }
        let speedValueInt = Int(speedValue)
        setSpeed(trainId: trainId, speedValue: speedValueInt)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                if response != nil {
                    self?.logStatus("Set speed to \(speedValueInt) for Train ID: \(trainId)")
                } else {
                    self?.logStatus("Failed to set speed for Train ID: \(trainId)")
                }
            }
            .store(in: &cancellables)
    }

    /// Sets the speed for a specific train.
    private func setSpeed(trainId: Int, speedValue: Int) -> Future<String?, Never> {
        let command = "set(\(trainId), speed[\(speedValue)])"
        return sendCommand(command)
    }

    /// Applies the direction setting to the selected train.
    func applyDirection() {
        guard let trainId = selectedTrain?.id else {
            logStatus("Please select a train to control.")
            return
        }
        let dirValue = direction == "Forward" ? 0 : 1
        setDirection(trainId: trainId, directionValue: dirValue)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                if response != nil {
                    self?.logStatus("Set direction to \(self?.direction ?? "") for Train ID: \(trainId)")
                } else {
                    self?.logStatus("Failed to set direction for Train ID: \(trainId)")
                }
            }
            .store(in: &cancellables)
    }

    /// Sets the direction for a specific train.
    private func setDirection(trainId: Int, directionValue: Int) -> Future<String?, Never> {
        let command = "set(\(trainId), dir[\(directionValue)])"
        return sendCommand(command)
    }

    /// Activates the killswitch or starts all trains based on the current state.
    func killswitch() {
        if trainsStopped {
            start()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] response in
                    if response != nil {
                        self?.logStatus("Trains started.")
                        self?.trainsStopped = false
                    } else {
                        self?.logStatus("Failed to start trains.")
                    }
                }
                .store(in: &cancellables)
        } else {
            stopAllTrains()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] response in
                    if response != nil {
                        self?.logStatus("Killswitch activated: All trains stopped.")
                        self?.trainsStopped = true
                        // Reset function states
                        DispatchQueue.main.async {
                            self?.functions = self?.functions.map { TrainFunction(id: $0.id, value: false) } ?? []
                        }
                    } else {
                        self?.logStatus("Failed to activate killswitch.")
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// Stops all trains by sending the appropriate command.
    private func stopAllTrains() -> Future<String?, Never> {
        let command = "set(1, stop)"
        return sendCommand(command)
    }

    /// Starts all trains by sending the appropriate command.
    private func start() -> Future<String?, Never> {
        let command = "set(1, go)"
        return sendCommand(command)
    }

    /// Logs status messages to the UI.
    private func logStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.status += message + "\n"
        }
    }

    /// Closes the network connection when the app is terminated.
    func close() {
        connection?.cancel()
        connection = nil
    }
}

// MARK: - Views

/// Displays a list of available trains for selection.
struct TrainListView: View {
    @ObservedObject var controller: RailroadController

    var body: some View {
        VStack {
            Text("Trains on Track")
                .font(.headline)
                .padding()

            List(controller.trains) { train in
                NavigationLink(
                    destination: ControlPanelView(controller: controller)
                ) {
                    Text("\(train.id) - \(train.name)")
                }
                .onTapGesture {
                    controller.selectedTrain = train
                    controller.onTrainSelect(train: train)
                }
            }

            Button(action: {
                controller.refreshTrains()
            }) {
                Text("Refresh Trains")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding()
        }
        .onAppear {
            controller.refreshTrains()
        }
    }
}

/// Provides control options for the selected train, including functions, speed, direction, and a killswitch.
struct ControlPanelView: View {
    @ObservedObject var controller: RailroadController

    var body: some View {
        VStack {
            if controller.selectedTrain != nil {
                // ZStack to overlay speed control on top of functions
                ZStack(alignment: .bottom) {
                    // Functions List
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Functions")
                                .font(.subheadline)
                                .padding(.bottom, 5)

                            ForEach(controller.functions) { function in
                                Toggle("Function \(function.id)", isOn: Binding<Bool>(
                                    get: { function.value },
                                    set: { newValue in
                                        // Optimized state update
                                        if let index = controller.functions.firstIndex(where: { $0.id == function.id }) {
                                            controller.functions[index].value = newValue
                                            controller.toggleFunction(function: controller.functions[index])
                                        }
                                    }
                                ))
                                .padding(.vertical, 2)
                            }
                        }
                        .padding()
                    }

                    // Speed Control Overlay
                    VStack {
                        Spacer()
                        HStack {
                            Text("Speed:")
                            Slider(value: $controller.speedValue, in: 0...100, step: 1)
                                .onChange(of: controller.speedValue) { newValue in
                                    controller.applySpeed()
                                }
                                .accentColor(.green)
                            Text("\(Int(controller.speedValue))")
                                .frame(width: 40)
                        }
                        .padding()
                        .background(Color(.systemBackground).opacity(0.9))
                        .cornerRadius(10)
                        .shadow(radius: 5)
                        .padding(.horizontal)
                    }
                }

                // Direction Control
                HStack {
                    Text("Direction:")
                    Picker("Direction", selection: $controller.direction) {
                        Text("Forward").tag("Forward")
                        Text("Reverse").tag("Reverse")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: controller.direction) { _ in
                        controller.applyDirection()
                    }
                }
                .padding()

                // Killswitch Button
                Button(action: {
                    controller.killswitch()
                }) {
                    Text(controller.trainsStopped ? "Trains Stopped (Click to Start)" : "RED BUTTON (Killswitch)")
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red)
                        .cornerRadius(8)
                }
                .padding()

                Spacer()
            } else {
                Text("Please select a train from the Trains tab.")
                    .foregroundColor(.gray)
                    .padding()
            }
        }
        .navigationBarTitle("Control Panel", displayMode: .inline)
    }
}

/// Displays the status logs of the application.
struct LogsView: View {
    @ObservedObject var controller: RailroadController

    var body: some View {
        VStack {
            Text("Status Logs")
                .font(.headline)
                .padding()

            ScrollView {
                Text(controller.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .navigationBarTitle("Logs", displayMode: .inline)
    }
}

/// The main content view containing a TabView with Trains, Control, and Logs tabs.
struct ContentView: View {
    @StateObject var controller: RailroadController

    var body: some View {
        TabView {
            // Trains Tab
            NavigationView {
                TrainListView(controller: controller)
            }
            .tabItem {
                Label("Trains", systemImage: "tram.fill")
            }

            // Control Tab
            NavigationView {
                ControlPanelView(controller: controller)
            }
            .tabItem {
                Label("Control", systemImage: "speedometer")
            }

            // Logs Tab
            NavigationView {
                LogsView(controller: controller)
            }
            .tabItem {
                Label("Logs", systemImage: "doc.text")
            }
        }
    }
}

// MARK: - App Entry Point

@main
struct RailroadApp: App {
    // Initialize the controller as a StateObject to ensure it's managed correctly
    @StateObject private var controller = RailroadController(ip: "192.168.0.27")

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onDisappear {
                    controller.close()
                }
        }
    }
}
