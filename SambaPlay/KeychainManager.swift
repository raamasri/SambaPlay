//
//  KeychainManager.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import Security

// MARK: - Keychain Manager for Secure Credential Storage
class KeychainManager {
    static let shared = KeychainManager()
    private init() {}
    
    // MARK: - Keychain Item Types
    enum KeychainError: Error, LocalizedError {
        case duplicateItem
        case itemNotFound
        case invalidData
        case unexpectedData
        case unhandledError(status: OSStatus)
        
        var errorDescription: String? {
            switch self {
            case .duplicateItem:
                return "Duplicate item in keychain"
            case .itemNotFound:
                return "Item not found in keychain"
            case .invalidData:
                return "Invalid data format"
            case .unexpectedData:
                return "Unexpected data in keychain"
            case .unhandledError(let status):
                return "Unhandled keychain error: \(status)"
            }
        }
    }
    
    // MARK: - Server Credentials
    struct ServerCredentials: Codable {
        let username: String
        let password: String
        let domain: String?
        let serverName: String
        let host: String
        let port: Int16
        
        init(username: String, password: String, domain: String? = nil, serverName: String, host: String, port: Int16 = 445) {
            self.username = username
            self.password = password
            self.domain = domain
            self.serverName = serverName
            self.host = host
            self.port = port
        }
    }
    
    // MARK: - Store Credentials
    func storeCredentials(_ credentials: ServerCredentials) throws {
        let service = "SambaPlay-SMB"
        let account = "\(credentials.host):\(credentials.port)"
        
        // Encode credentials to JSON
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(credentials) else {
            throw KeychainError.invalidData
        }
        
        // Create keychain query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Delete existing item if it exists
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }
    
    // MARK: - Retrieve Credentials
    func retrieveCredentials(for host: String, port: Int16 = 445) throws -> ServerCredentials {
        let service = "SambaPlay-SMB"
        let account = "\(host):\(port)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            } else {
                throw KeychainError.unhandledError(status: status)
            }
        }
        
        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }
        
        let decoder = JSONDecoder()
        do {
            let credentials = try decoder.decode(ServerCredentials.self, from: data)
            return credentials
        } catch {
            throw KeychainError.invalidData
        }
    }
    
    // MARK: - Delete Credentials
    func deleteCredentials(for host: String, port: Int16 = 445) throws {
        let service = "SambaPlay-SMB"
        let account = "\(host):\(port)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
    
    // MARK: - List All Stored Servers
    func getAllStoredServers() -> [String] {
        let service = "SambaPlay-SMB"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        
        let accounts = items.compactMap { item in
            item[kSecAttrAccount as String] as? String
        }
        
        return accounts
    }
    
    // MARK: - Update Credentials
    func updateCredentials(_ credentials: ServerCredentials) throws {
        // Delete existing credentials
        try? deleteCredentials(for: credentials.host, port: credentials.port)
        
        // Store new credentials
        try storeCredentials(credentials)
    }
    
    // MARK: - Check if Credentials Exist
    func hasCredentials(for host: String, port: Int16 = 445) -> Bool {
        do {
            _ = try retrieveCredentials(for: host, port: port)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Clear All Credentials
    func clearAllCredentials() throws {
        let service = "SambaPlay-SMB"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}

// MARK: - Keychain Manager Extensions
extension KeychainManager {
    
    // MARK: - Convenience Methods
    func storeServer(name: String, host: String, port: Int16, username: String, password: String, domain: String? = nil) throws {
        let credentials = ServerCredentials(
            username: username,
            password: password,
            domain: domain,
            serverName: name,
            host: host,
            port: port
        )
        try storeCredentials(credentials)
    }
} 