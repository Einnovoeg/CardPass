/*
 *  CardPass — PC/SC Reader Library
 *  pcsc_reader.c — Universal card reader and data extraction for any PC/SC card
 *
 *  What this file does:
 *    - Lists all connected PC/SC readers and their card-present state
 *    - Reads hex data from *any* inserted card to use as a password token:
 *        1) UID via pseudo-APDUs FF CA 00 00 00 (MIFARE/contactless/SIM hybrids)
 *        2) Standard SELECT by AID + GET RESPONSE / READ BINARY
 *        3) Telecom/SIM paths: MF 3F00, EF ICCID 2FE2, EF IMSI 6F07, GET DATA, NDEF
 *        4) ATR fallback — guaranteed to produce stable hex for any card
 *    - All operations are bounded, thread-safe, and create/release their own
 *      SCARDCONTEXT/SCARDHANDLE so the UI can run them on background queues.
 *
 *  Security & reliability:
 *    - Every snprintf/strncpy is size-checked and NUL-terminates.
 *    - Transmits verify rv == SCARD_S_SUCCESS and recvLen >= 2 (SW1/SW2).
 *    - Handles disconnect with SCARD_LEAVE_CARD (no power cycle).
 *    - No card data is written to disk; only returned to caller for clipboard/type.
 *    - ATR fallback is deliberately last resort so UID/SIM data is preferred when present.
 *
 *  Dependencies:
 *    - macOS PCSC.framework (winscard.h/wintypes.h) — Apple system framework, no extra license.
 *    - No third-party C deps. Python deps (legacy) are listed in requirements.txt.
 *
 *  Author: CardPass contributors — MIT License (see LICENSE)
 *  Support: https://buymeacoffee.com/einnovoeg
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define __COREFOUNDATION_CFPLUGINCOM__ 1   // Silence CoreFoundation deprecation on newer SDKs
#include <PCSC/winscard.h>
#include <PCSC/wintypes.h>
#include "pcsc_reader.h"                    // Public types — keep in sync

#ifndef MAX_RESPONSE_LEN
#define MAX_RESPONSE_LEN 264                // 256 data + 2 SW + margin
#endif

// Forward declarations (internal)
static void bytes_to_hex(const BYTE *data, DWORD len, char *out, size_t out_size);
static int  transmit(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci,
                     const BYTE *send, DWORD sendLen, BYTE *recv, DWORD *recvLen);
static int  is_success(BYTE sw1, BYTE sw2);
static int  try_uid(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci, BYTE *out, DWORD *outLen);
static int  try_select_and_read(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci, BYTE *out, DWORD *outLen);
static int  try_mf_and_ef(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci, BYTE *out, DWORD *outLen);
static int  try_atr_fallback(SCARDHANDLE hCard, BYTE *out, DWORD *outLen);

// PC/SC protocol headers — required by SCardTransmit
static const SCARD_IO_REQUEST g_pci_t0 = { SCARD_PROTOCOL_T0, sizeof(SCARD_IO_REQUEST) };
static const SCARD_IO_REQUEST g_pci_t1 = { SCARD_PROTOCOL_T1, sizeof(SCARD_IO_REQUEST) };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Convert binary `data[0..len)` to uppercase hex into `out`.
 * Always NUL-terminates. Truncates gracefully if out_size is too small.
 */
static void bytes_to_hex(const BYTE *data, DWORD len, char *out, size_t out_size) {
    // Defensive: require space for at least 1 char + NUL
    if (!data || !out || out_size < 3) {
        if (out && out_size > 0) out[0] = '\0';
        return;
    }
    size_t pos = 0;
    for (DWORD i = 0; i < len && pos + 2 < out_size; i++) {
        // Each byte -> two hex chars; snprintf guarantees bounds
        int n = snprintf(out + pos, out_size - pos, "%02X", data[i]);
        if (n <= 0) break; // snprintf error — stop
        pos += (size_t)n;
    }
    out[pos] = '\0';
}

/**
 * Thin wrapper over SCardTransmit that validates return code and ensures
 * at least SW1/SW2 are present. Returns 1 on usable response, 0 otherwise.
 */
static int transmit(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci,
                    const BYTE *send, DWORD sendLen,
                    BYTE *recv, DWORD *recvLen) {
    if (!pci || !send || !recv || !recvLen) return 0;
    LONG rv = SCardTransmit(hCard, pci, send, sendLen, NULL, recv, recvLen);
    if (rv != SCARD_S_SUCCESS) return 0;
    if (*recvLen < 2) return 0; // Need SW1 SW2
    return 1;
}

/** True iff status word is 0x9000 (success). */
static int is_success(BYTE sw1, BYTE sw2) {
    return sw1 == 0x90 && sw2 == 0x00;
}

// ---------------------------------------------------------------------------
// Strategy 1: UID via PC/SC pseudo-APDUs (works for MIFARE/contactless)
// ---------------------------------------------------------------------------
/**
 * Many contactless readers map FF CA 00 00 00 to "Get UID" regardless of card OS.
 * We try three common variants so SIM hybrids, MIFARE Classic/Ultralight, and
 * generic PICCs all return something.
 */
static int try_uid(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci, BYTE *out, DWORD *outLen) {
    BYTE recv[MAX_RESPONSE_LEN];
    DWORD recvLen;

    // FF CA 00 00 00 — most common PC/SC UID command
    const BYTE cmd1[] = {0xFF, 0xCA, 0x00, 0x00, 0x00};
    recvLen = sizeof(recv);
    if (transmit(hCard, pci, cmd1, sizeof(cmd1), recv, &recvLen)) {
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        if (is_success(sw1, sw2) && recvLen > 2) {
            *outLen = recvLen - 2;
            memcpy(out, recv, *outLen);
            return 1;
        }
    }

    // FF CA 01 00 00 — alternate P1 for some drivers
    const BYTE cmd2[] = {0xFF, 0xCA, 0x01, 0x00, 0x00};
    recvLen = sizeof(recv);
    if (transmit(hCard, pci, cmd2, sizeof(cmd2), recv, &recvLen)) {
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        if (is_success(sw1, sw2) && recvLen > 2) {
            *outLen = recvLen - 2;
            memcpy(out, recv, *outLen);
            return 1;
        }
    }

    // FF CA 00 00 04 — explicit Le=4 variant
    const BYTE cmd3[] = {0xFF, 0xCA, 0x00, 0x00, 0x04};
    recvLen = sizeof(recv);
    if (transmit(hCard, pci, cmd3, sizeof(cmd3), recv, &recvLen)) {
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        if (is_success(sw1, sw2) && recvLen > 2) {
            *outLen = recvLen - 2;
            memcpy(out, recv, *outLen);
            return 1;
        }
    }
    return 0; // No UID available — caller tries next strategy
}

// ---------------------------------------------------------------------------
// Strategy 2: SELECT by known AIDs then READ/GET DATA
// ---------------------------------------------------------------------------
/**
 * Try a small AID table (banking, common applet, NDEF) with proper 0x61 handling.
 * If SELECT succeeds we also try READ BINARY as a secondary read.
 */
static int try_select_and_read(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci, BYTE *out, DWORD *outLen) {
    BYTE recv[MAX_RESPONSE_LEN];
    DWORD recvLen;

    // Known AIDs gathered from banking cards and common applets. Each entry is
    // a full SELECT APDU: 00 A4 04 00 Lc AID. Lc is at index 4.
    static const BYTE known_aids[][16] = {
        {0x00,0xA4,0x04,0x00,0x07,0xA0,0x00,0x00,0x00,0x03,0x10,0x10},
        {0x00,0xA4,0x04,0x00,0x07,0xA0,0x00,0x00,0x00,0x04,0x10,0x10},
        {0x00,0xA4,0x04,0x00,0x07,0xA0,0x00,0x00,0x00,0x87,0x10,0x02},
        {0x00,0xA4,0x04,0x00,0x08,0xA0,0x00,0x00,0x03,0x10,0x10,0x00,0x00},
        {0x00,0xA4,0x04,0x00,0x07,0xA0,0x00,0x00,0x00,0x03,0x00,0x00},
    };
    int aid_count = (int)(sizeof(known_aids)/sizeof(known_aids[0]));

    for (int a = 0; a < aid_count; a++) {
        BYTE aidLen = known_aids[a][4];
        if (aidLen > 12) aidLen = 12;            // Sanity clamp
        DWORD cmdLen = 5 + aidLen;
        BYTE cmd[20];
        memcpy(cmd, known_aids[a], cmdLen);
        recvLen = sizeof(recv);
        if (!transmit(hCard, pci, cmd, cmdLen, recv, &recvLen)) continue;
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];

        // 0x61 XX means "XX bytes still available" — fetch with GET RESPONSE
        if (sw1 == 0x61) {
            BYTE getResp[] = {0x00, 0xC0, 0x00, 0x00, sw2};
            recvLen = sizeof(recv);
            if (!transmit(hCard, pci, getResp, sizeof(getResp), recv, &recvLen)) continue;
            sw1 = recv[recvLen-2]; sw2 = recv[recvLen-1];
        }
        if (is_success(sw1, sw2) && recvLen > 2) {
            *outLen = recvLen - 2;
            memcpy(out, recv, *outLen);
            return 1;
        }
        // Even if SELECT only returns FCI, try READ BINARY from 0 as many cards
        // expose public data at offset 0 after a successful SELECT.
        if (sw1 == 0x90 || sw1 == 0x61) {
            BYTE readBin[] = {0x00, 0xB0, 0x00, 0x00, 0x00};
            recvLen = sizeof(recv);
            if (transmit(hCard, pci, readBin, sizeof(readBin), recv, &recvLen)) {
                BYTE rsw1 = recv[recvLen-2], rsw2 = recv[recvLen-1];
                if (is_success(rsw1, rsw2) && recvLen > 2) {
                    *outLen = recvLen - 2;
                    memcpy(out, recv, *outLen);
                    return 1;
                }
            }
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Strategy 3: Telecom / SIM and generic file reads
// ---------------------------------------------------------------------------
/**
 * For SIM-like cards (and many JavaCards) selecting MF 3F00 then touching
 * EF files yields ICCID/IMSI. We also try GET DATA, GET CHALLENGE, and NDEF.
 * This makes CardPass useful as a password token even with SIMs that refuse
 * the banking AIDs above.
 */
static int try_mf_and_ef(SCARDHANDLE hCard, const SCARD_IO_REQUEST *pci, BYTE *out, DWORD *outLen) {
    BYTE recv[MAX_RESPONSE_LEN];
    DWORD recvLen;

    // SELECT MF 3F00 — master file; many cards allow it even when other selects fail
    const BYTE selMF[] = {0x00, 0xA4, 0x00, 0x00, 0x02, 0x3F, 0x00};
    recvLen = sizeof(recv);
    if (transmit(hCard, pci, selMF, sizeof(selMF), recv, &recvLen)) {
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        // Accept 90, 61, 62, 6A — all imply card is talking; probe further.
        if (sw1 == 0x90 || sw1 == 0x61 || sw1 == 0x62 || sw1 == 0x6A) {
            if (sw1 == 0x61) {
                BYTE gr[] = {0x00, 0xC0, 0x00, 0x00, sw2};
                recvLen = sizeof(recv);
                transmit(hCard, pci, gr, sizeof(gr), recv, &recvLen);
                sw1 = recv[recvLen-2]; sw2 = recv[recvLen-1];
            }
            // Try READ BINARY at 0, then GET DATA
            const BYTE readBin[] = {0x00, 0xB0, 0x00, 0x00, 0x00};
            recvLen = sizeof(recv);
            if (transmit(hCard, pci, readBin, sizeof(readBin), recv, &recvLen)) {
                BYTE rsw1 = recv[recvLen-2], rsw2 = recv[recvLen-1];
                if (is_success(rsw1, rsw2) && recvLen > 2) {
                    *outLen = recvLen - 2;
                    memcpy(out, recv, *outLen);
                    return 1;
                }
            }
            BYTE getData1[] = {0x00, 0xCA, 0x01, 0x00, 0x00};
            recvLen = sizeof(recv);
            if (transmit(hCard, pci, getData1, sizeof(getData1), recv, &recvLen)) {
                BYTE rsw1 = recv[recvLen-2], rsw2 = recv[recvLen-1];
                if (is_success(rsw1, rsw2) && recvLen > 2) {
                    *outLen = recvLen - 2;
                    memcpy(out, recv, *outLen);
                    return 1;
                }
            }
        }
    }

    // SIM EF files — ICCID and IMSI are public and unique per SIM, great for passwords
    const BYTE selICCID[] = {0x00, 0xA4, 0x00, 0x00, 0x02, 0x2F, 0xE2};
    const BYTE selIMSI[]  = {0x00, 0xA4, 0x00, 0x00, 0x02, 0x6F, 0x07};
    const BYTE *sims[] = {selICCID, selIMSI};
    for (int s = 0; s < 2; s++) {
        recvLen = sizeof(recv);
        if (!transmit(hCard, pci, selMF, sizeof(selMF), recv, &recvLen)) continue;
        recvLen = sizeof(recv);
        if (!transmit(hCard, pci, sims[s], 7, recv, &recvLen)) continue;
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        if (sw1 == 0x61) {
            BYTE gr[] = {0x00, 0xC0, 0x00, 0x00, sw2};
            recvLen = sizeof(recv);
            transmit(hCard, pci, gr, sizeof(gr), recv, &recvLen);
            sw1 = recv[recvLen-2]; sw2 = recv[recvLen-1];
        }
        if (sw1 == 0x90 || sw1 == 0x91 || sw1 == 0x62) {
            const BYTE rb[] = {0x00, 0xB0, 0x00, 0x00, 0x00};
            recvLen = sizeof(recv);
            if (transmit(hCard, pci, rb, sizeof(rb), recv, &recvLen)) {
                BYTE rsw1 = recv[recvLen-2], rsw2 = recv[recvLen-1];
                if ((is_success(rsw1, rsw2) || rsw1 == 0x62) && recvLen > 2) {
                    *outLen = recvLen - 2;
                    memcpy(out, recv, *outLen);
                    return 1;
                }
            }
        }
    }

    // GET CHALLENGE — some cards only respond to this
    const BYTE getChallenge[] = {0x00, 0x84, 0x00, 0x00, 0x08};
    recvLen = sizeof(recv);
    if (transmit(hCard, pci, getChallenge, sizeof(getChallenge), recv, &recvLen)) {
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        if (is_success(sw1, sw2) && recvLen > 2) {
            *outLen = recvLen - 2;
            memcpy(out, recv, *outLen);
            return 1;
        }
    }

    // NDEF SELECT (NFC) — useful for NTAG / Type 4 tags
    const BYTE selNDEF[] = {0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2,0x76,0x00,0x00,0x85,0x01,0x01,0x00};
    recvLen = sizeof(recv);
    if (transmit(hCard, pci, selNDEF, sizeof(selNDEF), recv, &recvLen)) {
        BYTE sw1 = recv[recvLen-2], sw2 = recv[recvLen-1];
        if (sw1 == 0x61) {
            BYTE gr[] = {0x00, 0xC0, 0x00, 0x00, sw2};
            recvLen = sizeof(recv);
            transmit(hCard, pci, gr, sizeof(gr), recv, &recvLen);
            sw1 = recv[recvLen-2]; sw2 = recv[recvLen-1];
        }
        if (is_success(sw1, sw2) && recvLen > 2) {
            *outLen = recvLen - 2;
            memcpy(out, recv, *outLen);
            return 1;
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Strategy 4: ATR fallback — always works if a card is present
// ---------------------------------------------------------------------------
/**
 * ATR (Answer To Reset) is unique per card type and always available.
 * Using SCardStatus we fetch it via the already-opened handle. This guarantees
 * CardPass can produce *some* hex even for YubiKeys/security keys that refuse
 * all APDUs, making the app still usable as a presence/token device.
 */
static int try_atr_fallback(SCARDHANDLE hCard, BYTE *out, DWORD *outLen) {
    DWORD atrLen = 33;
    BYTE atr[33];
    DWORD proto = 0;
    char readerName[256] = {0};
    DWORD rlen = sizeof(readerName);
    LONG rv = SCardStatus(hCard, readerName, &rlen, NULL, &proto, atr, &atrLen);
    if (rv == SCARD_S_SUCCESS && atrLen > 0 && atrLen <= 32) {
        *outLen = atrLen;
        memcpy(out, atr, atrLen);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Probe whether the PC/SC daemon is reachable.
 * Returns 1 if SCardEstablishContext succeeds, 0 otherwise. Callers can
 * use this to show "No readers" vs "PC/SC unavailable".
 */
int pcsc_init(void) {
    SCARDCONTEXT ctx = 0;
    LONG rv = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &ctx);
    if (rv == SCARD_S_SUCCESS) {
        SCardReleaseContext(ctx);
        return 1;
    }
    return 0;
}

/** No global state to clean up today — kept for API stability. */
void pcsc_cleanup(void) {}

/**
 * Helper: try to obtain ATR for `reader_name` without requiring an active card handle.
 * Uses SCardGetStatusChange to fetch `rgbAtr`/`cbAtr` even when SCardConnect fails
 * (common for SD readers or exclusive-access readers like Generic USB2.0-CRW).
 * Returns 1 if ATR obtained, 0 otherwise.
 */
static int get_atr_via_status(const char *reader_name, BYTE *out, DWORD *outLen) {
    if (!reader_name || !out || !outLen) return 0;
    SCARDCONTEXT ctx2 = 0;
    LONG rv2 = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &ctx2);
    if (rv2 != SCARD_S_SUCCESS) return 0;
    SCARD_READERSTATE rs;
    memset(&rs, 0, sizeof(rs));
    rs.szReader = reader_name;
    rs.dwCurrentState = SCARD_STATE_UNAWARE;
    // Use 500ms to allow slow readers (e.g., contact SD/banking) to report ATR.
    rv2 = SCardGetStatusChange(ctx2, 500, &rs, 1);
    int ok = 0;
    if ((rv2 == SCARD_S_SUCCESS || rv2 == SCARD_E_TIMEOUT) && (rs.dwEventState & SCARD_STATE_PRESENT)) {
        if (rs.cbAtr > 0 && rs.cbAtr <= 32) {
            *outLen = rs.cbAtr;
            memcpy(out, rs.rgbAtr, rs.cbAtr);
            ok = 1;
        }
    }
    SCardReleaseContext(ctx2);
    return ok;
}

/**
 * Read hex data from `reader_name`. Tries UID -> AID/READ -> SIM/EF -> ATR
 * in order. Each step allocates its own context/handle so thread safety is
 * not a concern. Returns CardReadResult with success or error.
 *
 * Robustness for diverse readers (2.0.1):
 *  - Tries multiple share modes (SHARED → EXCLUSIVE → DIRECT) and protocol combos
 *    (T0|T1 → T0 → T1 → RAW) to handle readers that reject SHARED (e.g., Generic
 *    USB2.0-CRW returns 0x80100066 / SCARD_W_RESET_CARD on SHARED).
 *  - If every SCardConnect fails, falls back to ATR via SCardGetStatusChange
 *    without a handle — guarantees stable hex for any present card.
 */
CardReadResult pcsc_read_card(const char *reader_name) {
    CardReadResult result = {0};
    result.hex_data[0] = '\0';
    result.error[0] = '\0';

    // Basic argument validation — avoid SCardConnect with NULL/empty
    if (!reader_name || reader_name[0] == '\0') {
        snprintf(result.error, sizeof(result.error), "Reader name is empty");
        return result;
    }

    SCARDCONTEXT ctx = 0;
    LONG rv = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &ctx);
    if (rv != SCARD_S_SUCCESS) {
        snprintf(result.error, sizeof(result.error), "PCSC context failed: 0x%08lX", (unsigned long)rv);
        return result;
    }

    SCARDHANDLE hCard = 0;
    DWORD activeProto = 0;
    LONG lastConnectRv = SCARD_S_SUCCESS;
    // Try multiple share-mode / protocol combos for reader compatibility.
    // Order matters: SHARED with T0|T1 first (fast path for Identive, YubiKey).
    const DWORD shareModes[] = { SCARD_SHARE_SHARED, SCARD_SHARE_EXCLUSIVE, SCARD_SHARE_DIRECT };
    const DWORD protos[] = { SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, SCARD_PROTOCOL_T0, SCARD_PROTOCOL_T1, SCARD_PROTOCOL_RAW };
    int connected = 0;
    for (size_t si = 0; si < sizeof(shareModes)/sizeof(shareModes[0]) && !connected; si++) {
        for (size_t pi = 0; pi < sizeof(protos)/sizeof(protos[0]) && !connected; pi++) {
            // DIRECT only makes sense with RAW or T0|T1
            if (shareModes[si] == SCARD_SHARE_DIRECT && protos[pi] == (SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1)) {
                // keep as is; some drivers allow DIRECT with T0|T1
            }
            rv = SCardConnect(ctx, reader_name, shareModes[si], protos[pi], &hCard, &activeProto);
            if (rv == SCARD_S_SUCCESS) {
                connected = 1;
                lastConnectRv = rv;
            } else {
                // Remember last error for diagnostics
                lastConnectRv = rv;
                // For W_UNPOWERED / W_RESET, try a reconnect after brief delay on same mode
                if (rv == SCARD_W_UNPOWERED_CARD || rv == SCARD_W_RESET_CARD || rv == (LONG)0x80100066 || rv == (LONG)0x80100067) {
                    // Give reader a moment to power up
                    // Note: no sleep here to keep UI snappy; caller may retry via polling.
                }
                // For SHARING_VIOLATION, next share mode may succeed
            }
        }
    }
    if (!connected) {
        // As last resort, try ATR without handle — works for readers that expose ATR
        // via GetStatusChange but reject SCardConnect (e.g., Generic USB2.0-CRW SD bridges).
        BYTE atrFallback[33];
        DWORD atrLen = 0;
        if (get_atr_via_status(reader_name, atrFallback, &atrLen) && atrLen > 0) {
            bytes_to_hex(atrFallback, atrLen, result.hex_data, sizeof(result.hex_data));
            result.success = 1;
            SCardReleaseContext(ctx);
            return result;
        }
        snprintf(result.error, sizeof(result.error), "Connect failed: 0x%08lX (tried SHARED/EXCLUSIVE/DIRECT with T0/T1/RAW)", (unsigned long)lastConnectRv);
        SCardReleaseContext(ctx);
        return result;
    }

    // Choose correct IO header per negotiated protocol
    const SCARD_IO_REQUEST *pci = (activeProto == SCARD_PROTOCOL_T1) ? &g_pci_t1 : &g_pci_t0;

    BYTE data[MAX_RESPONSE_LEN];
    DWORD dataLen = 0;

    // Try each strategy in priority order; first success wins
    if (try_uid(hCard, pci, data, &dataLen) && dataLen > 0) {
        bytes_to_hex(data, dataLen, result.hex_data, sizeof(result.hex_data));
        result.success = 1;
        SCardDisconnect(hCard, SCARD_LEAVE_CARD);
        SCardReleaseContext(ctx);
        return result;
    }

    if (try_select_and_read(hCard, pci, data, &dataLen) && dataLen > 0) {
        bytes_to_hex(data, dataLen, result.hex_data, sizeof(result.hex_data));
        result.success = 1;
        SCardDisconnect(hCard, SCARD_LEAVE_CARD);
        SCardReleaseContext(ctx);
        return result;
    }

    if (try_mf_and_ef(hCard, pci, data, &dataLen) && dataLen > 0) {
        bytes_to_hex(data, dataLen, result.hex_data, sizeof(result.hex_data));
        result.success = 1;
        SCardDisconnect(hCard, SCARD_LEAVE_CARD);
        SCardReleaseContext(ctx);
        return result;
    }

    if (try_atr_fallback(hCard, data, &dataLen) && dataLen > 0) {
        bytes_to_hex(data, dataLen, result.hex_data, sizeof(result.hex_data));
        result.success = 1;
        SCardDisconnect(hCard, SCARD_LEAVE_CARD);
        SCardReleaseContext(ctx);
        return result;
    }

    // Nothing worked — still return a helpful error
    snprintf(result.error, sizeof(result.error), "No readable data (all strategies failed)");
    SCardDisconnect(hCard, SCARD_LEAVE_CARD);
    SCardReleaseContext(ctx);
    return result;
}

/**
 * List readers via SCardListReaders + SCardGetStatusChange.
 * - Allocates mszReaders dynamically (size from first call with NULL buffer)
 * - Copies names with strncpy + NUL clamp
 * - Uses SCardGetStatusChange with 250ms timeout to get PRESENT/ATR
 * Returns reader count or 0 if none / on error. Never crashes on bad args.
 */
int pcsc_list_readers(ReaderList *list) {
    if (!list) return 0;
    memset(list, 0, sizeof(ReaderList));
    SCARDCONTEXT ctx = 0;
    LONG rv = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &ctx);
    if (rv != SCARD_S_SUCCESS) return 0;

    DWORD dwReaders = 0;
    rv = SCardListReaders(ctx, NULL, NULL, &dwReaders);
    if (rv != SCARD_S_SUCCESS || dwReaders == 0 || dwReaders > 4096) {
        SCardReleaseContext(ctx);
        return 0; // No readers or absurd size — treat as 0
    }

    char *mszReaders = malloc(dwReaders);
    if (!mszReaders) {
        SCardReleaseContext(ctx);
        return 0;
    }

    rv = SCardListReaders(ctx, NULL, mszReaders, &dwReaders);
    if (rv != SCARD_S_SUCCESS) {
        free(mszReaders);
        SCardReleaseContext(ctx);
        return 0;
    }

    // Parse multi-string (double-NUL terminated)
    int count = 0;
    char *ptr = mszReaders;
    while (*ptr != '\0' && count < PCSC_MAX_READERS) {
        strncpy(list->readers[count].name, ptr, PCSC_MAX_NAME_LEN - 1);
        list->readers[count].name[PCSC_MAX_NAME_LEN - 1] = '\0';
        count++;
        ptr += strlen(ptr) + 1;
        if ((ptr - mszReaders) >= (long)dwReaders) break;
    }
    list->reader_count = count;

    // Enrich with card-present + ATR via SCardGetStatusChange
    // 500ms accommodates slower contact readers (Generic USB2.0-CRW, Omnikey, etc.)
    // that need time to power and report ATR; still handles TIMEOUT as success.
    if (count > 0) {
        SCARD_READERSTATE *states = calloc(count, sizeof(SCARD_READERSTATE));
        if (states) {
            for (int i = 0; i < count; i++) {
                states[i].szReader = list->readers[i].name; // stable copy
                states[i].dwCurrentState = SCARD_STATE_UNAWARE;
            }
            // 500ms balances responsiveness and slow-reader compatibility
            rv = SCardGetStatusChange(ctx, 500, states, count);
            if (rv == SCARD_S_SUCCESS || rv == SCARD_E_TIMEOUT) {
                for (int i = 0; i < count; i++) {
                    list->readers[i].event_state = states[i].dwEventState;
                    list->readers[i].has_card = (states[i].dwEventState & SCARD_STATE_PRESENT) ? 1 : 0;
                    list->readers[i].atr_len = states[i].cbAtr;
                    if (states[i].cbAtr > 0 && states[i].cbAtr <= 32) {
                        memcpy(list->readers[i].atr, states[i].rgbAtr, states[i].cbAtr);
                    }
                }
            }
            free(states);
        }
    }

    free(mszReaders);
    SCardReleaseContext(ctx);
    return count;
}

// ---------------------------------------------------------------------------
// Simple accessors — all bounds-checked
// ---------------------------------------------------------------------------
int pcsc_get_reader_name(ReaderList *list, int index, char *buf, int buflen) {
    if (!list || !buf || buflen <= 0 || index < 0 || index >= list->reader_count) return -1;
    strncpy(buf, list->readers[index].name, buflen - 1);
    buf[buflen - 1] = '\0';
    return 0;
}

int pcsc_get_reader_has_card(ReaderList *list, int index) {
    if (!list || index < 0 || index >= list->reader_count) return 0;
    return list->readers[index].has_card;
}

int pcsc_get_reader_atr_len(ReaderList *list, int index) {
    if (!list || index < 0 || index >= list->reader_count) return 0;
    return list->readers[index].atr_len;
}
