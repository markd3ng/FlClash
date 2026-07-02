//go:build !cgo

package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

var conn net.Conn

// ipcKey is the per-session symmetric key for the local App<->core socket.
// It is delivered out-of-band via the FLCLASH_IPC_KEY environment variable at
// process launch, so it never traverses the socket itself. When unset the
// channel stays plaintext (backwards compatible).
var ipcKey []byte

func initIPCKey() {
	k := os.Getenv("FLCLASH_IPC_KEY")
	if k == "" {
		return
	}
	if raw, err := base64.StdEncoding.DecodeString(k); err == nil && len(raw) == chacha20poly1305.KeySize {
		ipcKey = raw
	}
}

// encodeFrame encrypts one newline-framed message: base64(nonce || sealed).
func encodeFrame(plaintext []byte) ([]byte, error) {
	if ipcKey == nil {
		return plaintext, nil
	}
	aead, err := chacha20poly1305.New(ipcKey)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, chacha20poly1305.NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	sealed := aead.Seal(nil, nonce, plaintext, nil)
	buf := make([]byte, 0, len(nonce)+len(sealed))
	buf = append(buf, nonce...)
	buf = append(buf, sealed...)
	return []byte(base64.StdEncoding.EncodeToString(buf)), nil
}

// decodeFrame reverses encodeFrame for one received line.
func decodeFrame(line string) ([]byte, error) {
	if ipcKey == nil {
		return []byte(line), nil
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(line))
	if err != nil {
		return nil, err
	}
	if len(raw) < chacha20poly1305.NonceSize {
		return nil, errors.New("ipc frame too short")
	}
	aead, err := chacha20poly1305.New(ipcKey)
	if err != nil {
		return nil, err
	}
	nonce := raw[:chacha20poly1305.NonceSize]
	return aead.Open(nil, nonce, raw[chacha20poly1305.NonceSize:], nil)
}

func (result ActionResult) send() {
	if conn == nil {
		return
	}
	data, err := result.Json()
	if err != nil {
		return
	}
	send(data)
}

func sendMessage(message Message) {
	result := ActionResult{
		Method: messageMethod,
		Data:   message,
	}
	result.send()
}

func send(data []byte) {
	if conn == nil {
		return
	}
	frame, err := encodeFrame(data)
	if err != nil {
		return
	}
	_, _ = conn.Write(append(frame, '\n'))
}

func startServer(arg string) {

	initIPCKey()

	_, err := strconv.Atoi(arg)

	var dialErr error
	for i := 0; i < 5; i++ {
		if err != nil {
			conn, dialErr = net.Dial("unix", arg)
		} else {
			conn, dialErr = net.Dial("tcp", fmt.Sprintf("127.0.0.1:%s", arg))
		}
		if dialErr == nil {
			break
		}
		time.Sleep(time.Second)
	}

	if dialErr != nil {
		log.Println("Connection failed:", dialErr)
		return
	}

	defer func(conn net.Conn) {
		_ = conn.Close()
	}(conn)

	reader := bufio.NewReader(conn)

	for {
		data, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		plain, err := decodeFrame(data)
		if err != nil {
			return
		}
		var action = &Action{}

		err = json.Unmarshal(plain, action)

		if err != nil {
			return
		}

		result := ActionResult{
			Id:     action.Id,
			Method: action.Method,
		}

		go handleAction(action, result)
	}
}

func nextHandle(action *Action, result ActionResult) bool {
	return false
}
