import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct MicroPairedDeviceRecord: Codable, Equatable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var platform: String
    public var devicePublicKey: String?
    public var pairedAtMs: Int64
    public var lastSeenAtMs: Int64
    public var isRevoked: Bool

    public init(
        deviceID: String,
        deviceName: String,
        platform: String,
        devicePublicKey: String? = nil,
        pairedAtMs: Int64,
        lastSeenAtMs: Int64,
        isRevoked: Bool = false
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.devicePublicKey = devicePublicKey
        self.pairedAtMs = pairedAtMs
        self.lastSeenAtMs = lastSeenAtMs
        self.isRevoked = isRevoked
    }
}

public struct MicroHostIdentityRecord: Codable, Equatable, Sendable {
    public var hostID: String
    public var privateKeyBase64: String
    public var publicKeyBase64: String
}

public enum MicroLedgerBeginOutcome: Sendable {
    case started
    case existing(MicroRemoteCommandAckPayload)
    case payloadConflict
}

public final class MicroRemoteStoreDB: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(databaseURL: URL) throws {
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "MicroRemoteStoreDB", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: message])
        }
        self.db = handle
        try migrateAndRecover()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func migrateAndRecover() throws {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;

        CREATE TABLE IF NOT EXISTS host_identity (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            host_id TEXT NOT NULL,
            private_key_base64 TEXT NOT NULL,
            public_key_base64 TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS pairing_tokens (
            token_hash TEXT PRIMARY KEY,
            expires_at_ms INTEGER NOT NULL,
            consumed INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS paired_devices (
            device_id TEXT PRIMARY KEY,
            device_name TEXT NOT NULL,
            platform TEXT NOT NULL,
            token_hash TEXT NOT NULL,
            device_public_key TEXT,
            paired_at_ms INTEGER NOT NULL,
            last_seen_at_ms INTEGER NOT NULL,
            revoked INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS command_ledger (
            device_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            payload_hash TEXT NOT NULL,
            command_type TEXT NOT NULL,
            status TEXT NOT NULL,
            revision INTEGER NOT NULL,
            thread_id TEXT,
            turn_id TEXT,
            approval_request_id TEXT,
            error_code TEXT,
            message TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (device_id, request_id)
        );

        UPDATE command_ledger
           SET status = 'unknown',
               error_code = 'host_restarted_during_execution',
               message = 'Host restarted while command was in progress'
         WHERE status = 'in_progress';
        """
        try executeStatements(sql)
    }

    private func executeStatements(_ sql: String) throws {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let text = errMsg.map { String(cString: $0) } ?? "SQLite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw NSError(domain: "MicroRemoteStoreDB", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    public func loadOrCreateHostIdentity() -> MicroHostIdentityRecord {
        lock.lock()
        defer { lock.unlock() }

        let selectSQL = "SELECT host_id, private_key_base64, public_key_base64 FROM host_identity WHERE singleton = 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW,
               let hostIDPtr = sqlite3_column_text(stmt, 0),
               let privPtr = sqlite3_column_text(stmt, 1),
               let pubPtr = sqlite3_column_text(stmt, 2) {
                return MicroHostIdentityRecord(
                    hostID: String(cString: hostIDPtr),
                    privateKeyBase64: String(cString: privPtr),
                    publicKeyBase64: String(cString: pubPtr)
                )
            }
        }

        let hostID = "host-" + UUID().uuidString.lowercased().prefix(12)
        let keyPair = MicroRemoteCrypto.generateKeyPair()
        let insertSQL = """
        INSERT OR REPLACE INTO host_identity (singleton, host_id, private_key_base64, public_key_base64)
        VALUES (1, ?, ?, ?);
        """
        var insertStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(insertStmt) }
            bindText(insertStmt, index: 1, value: hostID)
            bindText(insertStmt, index: 2, value: keyPair.privateKeyBase64)
            bindText(insertStmt, index: 3, value: keyPair.publicKeyBase64)
            _ = sqlite3_step(insertStmt)
        }

        return MicroHostIdentityRecord(
            hostID: hostID,
            privateKeyBase64: keyPair.privateKeyBase64,
            publicKeyBase64: keyPair.publicKeyBase64
        )
    }

    public func issuePairingToken(ttlSeconds: Int = 300) -> (token: String, expiresAtMs: Int64) {
        lock.lock()
        defer { lock.unlock() }

        let rawToken = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let tokenHash = MicroRemoteCrypto.sha256Hex(rawToken)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let expiresAtMs = nowMs + Int64(ttlSeconds) * 1000

        let cleanupSQL = "DELETE FROM pairing_tokens WHERE expires_at_ms < ? OR consumed = 1;"
        var cleanStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cleanupSQL, -1, &cleanStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(cleanStmt) }
            sqlite3_bind_int64(cleanStmt, 1, nowMs)
            _ = sqlite3_step(cleanStmt)
        }

        let insertSQL = "INSERT OR REPLACE INTO pairing_tokens (token_hash, expires_at_ms, consumed) VALUES (?, ?, 0);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: tokenHash)
            sqlite3_bind_int64(stmt, 2, expiresAtMs)
            _ = sqlite3_step(stmt)
        }

        return (rawToken, expiresAtMs)
    }

    public func exchangePairingToken(
        rawPairingToken: String,
        deviceID: String,
        deviceName: String,
        platform: String,
        devicePublicKey: String?
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let pairingHash = MicroRemoteCrypto.sha256Hex(rawPairingToken)

        let checkSQL = "SELECT expires_at_ms, consumed FROM pairing_tokens WHERE token_hash = ?;"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(checkStmt) }
        bindText(checkStmt, index: 1, value: pairingHash)
        guard sqlite3_step(checkStmt) == SQLITE_ROW else { return nil }
        let expiresAtMs = sqlite3_column_int64(checkStmt, 0)
        let consumed = sqlite3_column_int(checkStmt, 1)
        guard consumed == 0, expiresAtMs >= nowMs else { return nil }

        let consumeSQL = "UPDATE pairing_tokens SET consumed = 1 WHERE token_hash = ?;"
        var consumeStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, consumeSQL, -1, &consumeStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(consumeStmt) }
            bindText(consumeStmt, index: 1, value: pairingHash)
            _ = sqlite3_step(consumeStmt)
        }

        let deviceToken = "dt_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let deviceTokenHash = MicroRemoteCrypto.sha256Hex(deviceToken)

        let upsertSQL = """
        INSERT INTO paired_devices (
            device_id, device_name, platform, token_hash, device_public_key, paired_at_ms, last_seen_at_ms, revoked
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(device_id) DO UPDATE SET
            device_name = excluded.device_name,
            platform = excluded.platform,
            token_hash = excluded.token_hash,
            device_public_key = excluded.device_public_key,
            last_seen_at_ms = excluded.last_seen_at_ms,
            revoked = 0;
        """
        var upsertStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(upsertStmt) }
            bindText(upsertStmt, index: 1, value: deviceID)
            bindText(upsertStmt, index: 2, value: deviceName)
            bindText(upsertStmt, index: 3, value: platform)
            bindText(upsertStmt, index: 4, value: deviceTokenHash)
            bindOptionalText(upsertStmt, index: 5, value: devicePublicKey)
            sqlite3_bind_int64(upsertStmt, 6, nowMs)
            sqlite3_bind_int64(upsertStmt, 7, nowMs)
            _ = sqlite3_step(upsertStmt)
        }

        return deviceToken
    }

    public func authenticateDevice(deviceID: String, rawDeviceToken: String) -> MicroPairedDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }

        let tokenHash = MicroRemoteCrypto.sha256Hex(rawDeviceToken)
        let sql = """
        SELECT device_name, platform, device_public_key, paired_at_ms, last_seen_at_ms, revoked
          FROM paired_devices
         WHERE device_id = ? AND token_hash = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: deviceID)
        bindText(stmt, index: 2, value: tokenHash)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let revoked = sqlite3_column_int(stmt, 5) != 0
        guard !revoked else { return nil }

        let deviceName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? deviceID
        let platform = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "ios"
        let pubKey = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let pairedAt = sqlite3_column_int64(stmt, 3)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let touchSQL = "UPDATE paired_devices SET last_seen_at_ms = ? WHERE device_id = ?;"
        var touchStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, touchSQL, -1, &touchStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(touchStmt) }
            sqlite3_bind_int64(touchStmt, 1, nowMs)
            bindText(touchStmt, index: 2, value: deviceID)
            _ = sqlite3_step(touchStmt)
        }

        return MicroPairedDeviceRecord(
            deviceID: deviceID,
            deviceName: deviceName,
            platform: platform,
            devicePublicKey: pubKey,
            pairedAtMs: pairedAt,
            lastSeenAtMs: nowMs,
            isRevoked: false
        )
    }

    public func listPairedDevices() -> [MicroPairedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
        SELECT device_id, device_name, platform, device_public_key, paired_at_ms, last_seen_at_ms, revoked
          FROM paired_devices
         WHERE revoked = 0
         ORDER BY last_seen_at_ms DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var records: [MicroPairedDeviceRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let namePtr = sqlite3_column_text(stmt, 1),
                  let platformPtr = sqlite3_column_text(stmt, 2) else { continue }
            let pubKey = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            records.append(
                MicroPairedDeviceRecord(
                    deviceID: String(cString: idPtr),
                    deviceName: String(cString: namePtr),
                    platform: String(cString: platformPtr),
                    devicePublicKey: pubKey,
                    pairedAtMs: sqlite3_column_int64(stmt, 4),
                    lastSeenAtMs: sqlite3_column_int64(stmt, 5),
                    isRevoked: sqlite3_column_int(stmt, 6) != 0
                )
            )
        }
        return records
    }

    public func revokeDevice(deviceID: String) {
        lock.lock()
        defer { lock.unlock() }

        let sql = "UPDATE paired_devices SET revoked = 1 WHERE device_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: deviceID)
            _ = sqlite3_step(stmt)
        }
    }

    public func beginOrReuseCommand(
        deviceID: String,
        requestID: String,
        payloadHash: String,
        commandType: String,
        revision: Int,
        threadID: String? = nil,
        turnID: String? = nil,
        approvalRequestID: String? = nil
    ) -> MicroLedgerBeginOutcome {
        lock.lock()
        defer { lock.unlock() }

        if let existing = readCommandLocked(deviceID: deviceID, requestID: requestID) {
            if existing.payloadHash != payloadHash {
                return .payloadConflict
            }
            return .existing(existing.ack)
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let insertSQL = """
        INSERT INTO command_ledger (
            device_id, request_id, payload_hash, command_type, status, revision,
            thread_id, turn_id, approval_request_id, error_code, message, created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, 'in_progress', ?, ?, ?, ?, NULL, NULL, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: deviceID)
            bindText(stmt, index: 2, value: requestID)
            bindText(stmt, index: 3, value: payloadHash)
            bindText(stmt, index: 4, value: commandType)
            sqlite3_bind_int(stmt, 5, Int32(revision))
            bindOptionalText(stmt, index: 6, value: threadID)
            bindOptionalText(stmt, index: 7, value: turnID)
            bindOptionalText(stmt, index: 8, value: approvalRequestID)
            sqlite3_bind_int64(stmt, 9, nowMs)
            sqlite3_bind_int64(stmt, 10, nowMs)
            _ = sqlite3_step(stmt)
        }

        return .started
    }

    public func completeCommand(
        deviceID: String,
        requestID: String,
        status: MicroRemoteCommandOutcomeStatus,
        revision: Int,
        threadID: String? = nil,
        turnID: String? = nil,
        approvalRequestID: String? = nil,
        errorCode: String? = nil,
        message: String? = nil
    ) -> MicroRemoteCommandAckPayload? {
        lock.lock()
        defer { lock.unlock() }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let updateSQL = """
        UPDATE command_ledger
           SET status = ?,
               revision = ?,
               thread_id = COALESCE(?, thread_id),
               turn_id = COALESCE(?, turn_id),
               approval_request_id = COALESCE(?, approval_request_id),
               error_code = ?,
               message = ?,
               updated_at_ms = ?
         WHERE device_id = ? AND request_id = ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: status.rawValue)
            sqlite3_bind_int(stmt, 2, Int32(revision))
            bindOptionalText(stmt, index: 3, value: threadID)
            bindOptionalText(stmt, index: 4, value: turnID)
            bindOptionalText(stmt, index: 5, value: approvalRequestID)
            bindOptionalText(stmt, index: 6, value: errorCode)
            bindOptionalText(stmt, index: 7, value: message)
            sqlite3_bind_int64(stmt, 8, nowMs)
            bindText(stmt, index: 9, value: deviceID)
            bindText(stmt, index: 10, value: requestID)
            _ = sqlite3_step(stmt)
        }

        return readCommandLocked(deviceID: deviceID, requestID: requestID)?.ack
    }

    public func queryCommand(deviceID: String, requestID: String) -> MicroRemoteCommandAckPayload? {
        lock.lock()
        defer { lock.unlock() }
        return readCommandLocked(deviceID: deviceID, requestID: requestID)?.ack
    }

    private func readCommandLocked(
        deviceID: String,
        requestID: String
    ) -> (payloadHash: String, ack: MicroRemoteCommandAckPayload)? {
        let sql = """
        SELECT payload_hash, command_type, status, revision, thread_id, turn_id, approval_request_id, error_code, message
          FROM command_ledger
         WHERE device_id = ? AND request_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: deviceID)
        bindText(stmt, index: 2, value: requestID)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let hashPtr = sqlite3_column_text(stmt, 0),
              let typePtr = sqlite3_column_text(stmt, 1),
              let statusPtr = sqlite3_column_text(stmt, 2) else {
            return nil
        }

        let payloadHash = String(cString: hashPtr)
        let commandType = String(cString: typePtr)
        let statusRaw = String(cString: statusPtr)
        let status = MicroRemoteCommandOutcomeStatus(rawValue: statusRaw) ?? .unknown
        let revision = Int(sqlite3_column_int(stmt, 3))
        let threadID = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let turnID = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let approvalID = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let errorCode = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let message = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

        return (
            payloadHash,
            MicroRemoteCommandAckPayload(
                commandType: commandType,
                status: status,
                revision: revision,
                threadID: threadID,
                turnID: turnID,
                approvalRequestID: approvalID,
                errorCode: errorCode,
                message: message
            )
        )
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
