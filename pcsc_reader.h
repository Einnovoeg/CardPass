/*
 *  CardPass — PC/SC Reader Library
 *  pcsc_reader.h — Public interface for smart card reader detection and card data extraction
 *
 *  Overview:
 *    This header exposes a small, thread-safe C interface for listing PC/SC readers
 *    and reading card data. It wraps Apple's PC/SC (winscard) framework and tries
 *    multiple APDU strategies so a wide range of cards work as hardware password tokens:
 *      - UID via FF CA (MIFARE / contactless)
 *      - Standard SELECT + READ BINARY / GET DATA
 *      - SIM / telecom EF paths (MF 3F00, ICCID 2FE2, IMSI 6F07)
 *      - ATR fallback (guaranteed hex for any present card)
 *
 *  Security notes:
 *    - No secrets are logged or persisted. Card data stays in memory only
 *      until copied/typed by the user.
 *    - All buffers are bounded; snprintf/strncpy always NUL-terminate.
 *    - Each operation creates and releases its own SCARDCONTEXT/SCARDHANDLE
 *      so callers can run on any thread.
 *    - Handles are disconnected with SCARD_LEAVE_CARD to avoid power-cycling.
 *
 *  Author: CardPass contributors
 *  License: MIT (see LICENSE). Third-party: PC/SC framework is part of macOS (Apple).
 *  Buy Me a Coffee: https://buymeacoffee.com/einnovoeg — support the project!
 */

#ifndef PCSC_READER_H
#define PCSC_READER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Maximum sizes — keep in sync with implementation
#define PCSC_MAX_HEX_LEN   1024  // 512 bytes -> 1024 hex chars + NUL
#define PCSC_MAX_ERR_LEN    256
#define PCSC_MAX_READERS     16
#define PCSC_MAX_ATR_LEN     33
#define PCSC_MAX_NAME_LEN   256

/**
 * Result of a card read attempt.
 *  success = 1  -> hex_data contains uppercase hex (NUL-terminated)
 *  success = 0  -> error contains human-readable reason
 */
typedef struct {
    int  success;
    char hex_data[PCSC_MAX_HEX_LEN + 1];
    char error[PCSC_MAX_ERR_LEN];
} CardReadResult;

/** Per-reader state returned by pcsc_list_readers */
typedef struct {
    char         name[PCSC_MAX_NAME_LEN];
    unsigned int event_state;          // SCARD_STATE_* bitmask
    unsigned char atr[PCSC_MAX_ATR_LEN];
    unsigned int atr_len;
    int          has_card;             // boolean
} ReaderInfo;

/** List of all detected readers */
typedef struct {
    int        reader_count;
    ReaderInfo readers[PCSC_MAX_READERS];
} ReaderList;

// Lifecycle
int  pcsc_init(void);        // Returns 1 if PC/SC available, 0 otherwise. Cheap probe.
void pcsc_cleanup(void);     // No-op today; keeps API future-proof.

// Core operations (thread-safe; each creates its own context)
int            pcsc_list_readers(ReaderList *list);                               // Returns count or 0
CardReadResult pcsc_read_card(const char *reader_name);                           // Tries UID -> SELECT -> SIM -> ATR
int            pcsc_get_reader_name(ReaderList *list, int index, char *buf, int buflen);
int            pcsc_get_reader_has_card(ReaderList *list, int index);
int            pcsc_get_reader_atr_len(ReaderList *list, int index);

#ifdef __cplusplus
}
#endif

#endif // PCSC_READER_H
