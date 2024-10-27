import SwiftUI
import Network
import Foundation
import Combine // Ensure Combine is imported

// MARK: - Train Model
struct Train: Identifiable, Hashable, Equatable {
    let id: Int
    let name: String
}

// MARK: - TrainFunction Model
struct TrainFunction: Identifiable {
    let id: Int
    var value: Bool
}

// MARK: - RailroadController Class
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

    init(ip: String, port: UInt16 = 15471) {
        self.ip = ip
        self.port = port
        connect()
    }

    // MARK: - Network Connection Methods

    // Connect to the controller via TCP
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
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    // Receive data from the controller
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
                // Attempt to reconnect
                self?.connect()
            }
        }
    }

    // Process received data and handle responses or events
    private func processReceivedData(_ data: String) {
        receiveBuffer += data
        if receiveBuffer.contains("<END") {
            let response = receiveBuffer
            receiveBuffer = ""
            DispatchQueue.main.async {
                self.currentCompletionHandler?(response)
                self.currentCompletionHandler = nil
            }
        } else if data.contains("<EVENT") {
            processEvent(data)
        }
    }

    // Process EVENT messages from the controller
    private func processEvent(_ data: String) {
        let lines = data.split(separator: "\n")
        for line in lines where line.starts(with: "<EVENT") {
            let eventDescription = line.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            print("Received EVENT: \(eventDescription)")
            // Handle event if needed
        }
    }

    // Send a command to the controller
    private func sendCommand(_ command: String, completion: @escaping (String?) -> Void) {
        if connection == nil {
            connect()
        }
        currentCompletionHandler = completion
        let message = command + "\n"
        if let data = message.data(using: .utf8) {
            connection?.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    print("Send failed: \(error)")
                    self.connection = nil
                    completion(nil)
                }
            }))
        }
    }

    // MARK: - Train Management Methods

    // Refresh the list of trains
    func refreshTrains() {
        sendCommand("queryObjects(10, name)") { [weak self] response in
            if let response = response {
                print("Response from controller: \(response)")
                self?.parseAndDisplayTrains(response)
            } else {
                self?.logStatus("Failed to retrieve trains.")
            }
        }
    }

    // Parse and display the list of trains
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
        DispatchQueue.main.async {
            self.trains = trainsList
            self.logStatus("Trains list updated.")
            print("Updated trains array with \(trainsList.count) trains.") // Debugging output
        }
    }

    // Handle train selection
    func onTrainSelect(train: Train) {
        logStatus("Selected Train ID: \(train.id)")
        loadTrainFunctions()
    }

    // Load the functions for the selected train
    private func loadTrainFunctions() {
        guard let trainId = selectedTrain?.id else { return }
        sendCommand("get(\(trainId), func)") { [weak self] response in
            if let response = response {
                print("Response from controller (functions):\n\(response)") // Debugging output
                self?.parseAndDisplayFunctions(response, for: trainId)
            } else {
                self?.logStatus("Failed to retrieve function settings for Train ID: \(trainId).")
            }
        }
    }

    // Parse and display the functions for a specific train
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
        
        DispatchQueue.main.async {
            self.functions = functionList.sorted { $0.id < $1.id }
            self.logStatus("Loaded \(functionList.count) functions for Train ID: \(trainId)")
            print("Loaded \(functionList.count) functions for Train ID: \(trainId)") // Debugging output
        }
    }

    // MARK: - Control Methods

    // Toggle a train function
    func toggleFunction(function: TrainFunction) {
        guard let trainId = selectedTrain?.id else {
            logStatus("Please select a train to control.")
            return
        }
        let intValue = function.value ? 1 : 0
        setFunction(trainId: trainId, funcId: function.id, value: intValue) { [weak self] response in
            if response != nil {
                self?.logStatus("Set function \(function.id) to \(intValue) for Train ID: \(trainId)")
            } else {
                self?.logStatus("Failed to set function \(function.id) for Train ID: \(trainId)")
            }
        }
    }

    // Set a specific function for a train
    private func setFunction(trainId: Int, funcId: Int, value: Int, completion: @escaping (String?) -> Void) {
        let command = "set(\(trainId), func[\(funcId), \(value)])"
        sendCommand(command, completion: completion)
    }

    // Apply speed to the selected train
    func applySpeed() {
        guard let trainId = selectedTrain?.id else {
            logStatus("Please select a train to control.")
            return
        }
        let speedValueInt = Int(speedValue)
        setSpeed(trainId: trainId, speedValue: speedValueInt) { [weak self] response in
            if response != nil {
                self?.logStatus("Set speed to \(speedValueInt) for Train ID: \(trainId)")
            } else {
                self?.logStatus("Failed to set speed for Train ID: \(trainId)")
            }
        }
    }

    // Set the speed for a train
    private func setSpeed(trainId: Int, speedValue: Int, completion: @escaping (String?) -> Void) {
        let command = "set(\(trainId), speed[\(speedValue)])"
        sendCommand(command, completion: completion)
    }

    // Apply direction to the selected train
    func applyDirection() {
        guard let trainId = selectedTrain?.id else {
            logStatus("Please select a train to control.")
            return
        }
        let dirValue = direction == "Forward" ? 0 : 1
        setDirection(trainId: trainId, directionValue: dirValue) { [weak self] response in
            if response != nil {
                self?.logStatus("Set direction to \(self?.direction ?? "") for Train ID: \(trainId)")
            } else {
                self?.logStatus("Failed to set direction for Train ID: \(trainId)")
            }
        }
    }

    // Set the direction for a train
    private func setDirection(trainId: Int, directionValue: Int, completion: @escaping (String?) -> Void) {
        let command = "set(\(trainId), dir[\(directionValue)])"
        sendCommand(command, completion: completion)
    }

    // Activate the killswitch or start all trains
    func killswitch() {
        if trainsStopped {
            start { [weak self] response in
                if response != nil {
                    self?.logStatus("Trains started.")
                    self?.trainsStopped = false
                } else {
                    self?.logStatus("Failed to start trains.")
                }
            }
        } else {
            stopAllTrains { [weak self] response in
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
        }
    }

    // Stop all trains
    private func stopAllTrains(completion: @escaping (String?) -> Void) {
        let command = "set(1, stop)"
        sendCommand(command, completion: completion)
    }

    // Start all trains
    private func start(completion: @escaping (String?) -> Void) {
        let command = "set(1, go)"
        sendCommand(command, completion: completion)
    }

    // Log status messages
    private func logStatus(_ message: String) {
        DispatchQueue.main.async {
            self.status += message + "\n"
        }
    }

    // Close the connection when the app is terminated
    func close() {
        connection?.cancel()
        connection = nil
    }
}

// MARK: - ContentView
struct ContentView: View {
    @ObservedObject var controller: RailroadController

    var body: some View {
        HStack {
            // Train List
            VStack {
                Text("Trains on Track")
                    .font(.headline)
                List(selection: $controller.selectedTrain) {
                    ForEach(controller.trains) { train in
                        Text("\(train.id) - \(train.name)")
                            .tag(train)
                    }
                }
                .onChange(of: controller.selectedTrain) { newValue in
                    if let train = newValue {
                        controller.onTrainSelect(train: train)
                    }
                }
                Button("Refresh Trains") {
                    controller.refreshTrains()
                }
                .padding(.top, 10)
            }
            .frame(minWidth: 200)
            .padding()

            Divider()

            // Control Panel
            VStack {
                Text("Control Panel")
                    .font(.headline)
                // Speed Control
                HStack {
                    Text("Speed:")
                    Slider(value: $controller.speedValue, in: 0...100, step: 1) { editing in
                        if !editing {
                            controller.applySpeed()
                        }
                    }
                    Text("\(Int(controller.speedValue))")
                        .frame(width: 30)
                }
                .padding(.vertical)
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
                .padding(.vertical)
                // Function Controls
                VStack {
                    Text("Functions")
                        .font(.subheadline)
                    ScrollView {
                        ForEach(controller.functions) { function in
                            Toggle("Function \(function.id)", isOn: Binding<Bool>(
                                get: { function.value },
                                set: { newValue in
                                    if let index = controller.functions.firstIndex(where: { $0.id == function.id }) {
                                        controller.functions[index].value = newValue
                                        controller.toggleFunction(function: controller.functions[index])
                                    }
                                }
                            ))
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxHeight: 200)
                }
                .padding(.vertical)
                // RED BUTTON (Killswitch)
                Button(action: {
                    controller.killswitch()
                }) {
                    Text(controller.trainsStopped ? "Trains Stopped (Click to Start)" : "RED BUTTON (Killswitch)")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(8)
                }
                .padding(.vertical)
            }
            .frame(minWidth: 300)
            .padding()

            Divider()

            // Status Display
            VStack {
                Text("Status")
                    .font(.headline)
                ScrollView {
                    Text(controller.status)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .frame(minWidth: 300)
            .padding()
        }
    }
}

// MARK: - Main App
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
