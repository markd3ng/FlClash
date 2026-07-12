package com.follow.clash.service;

import com.follow.clash.service.ICallbackInterface;
import com.follow.clash.service.IAckInterface;

interface IValidatorInterface {
	void begin(in String initAction, in ICallbackInterface callback, in IAckInterface ack);
	void sendChunk(in byte[] data, boolean isLast, in IAckInterface ack);
    void shutdown();
}