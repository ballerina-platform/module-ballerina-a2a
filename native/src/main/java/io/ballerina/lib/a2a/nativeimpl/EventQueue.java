/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.a2a.nativeimpl;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BDecimal;
import io.ballerina.runtime.api.values.BObject;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;

/**
 * The blocking queue behind {@code EventQueue} in {@code event_queue.bal}: one subscriber's inbox of a task's events.
 * <p>
 * Producers never block ({@code put} on an unbounded deque). A consumer that finds the queue empty yields its strand
 * through {@link Environment#yieldAndRun} and waits on the deque, so it costs nothing while idle and wakes the moment
 * an element arrives or its timeout passes.
 */
public final class EventQueue {

    private static final String QUEUE = "queue";
    private static final BigDecimal MILLIS_PER_SECOND = BigDecimal.valueOf(1000);

    private EventQueue() {
    }

    public static void externInit(BObject self) {
        self.addNativeData(QUEUE, new LinkedBlockingDeque<Object>());
    }

    public static void put(BObject self, Object item) {
        queue(self).addLast(item);
    }

    public static void putFirst(BObject self, Object item) {
        queue(self).addFirst(item);
    }

    /**
     * Removes the head of the queue, waiting for one if it is empty.
     *
     * @param environment    the calling strand's environment
     * @param self           the {@code EventQueue} object
     * @param timeoutSeconds the longest wait in seconds as a {@code BDecimal}, or {@code null} to wait without limit
     * @return the head element, {@code null} if the timeout passed with the queue still empty, or an error if the
     *         wait was interrupted
     */
    public static Object take(Environment environment, BObject self, Object timeoutSeconds) {
        LinkedBlockingDeque<Object> queue = queue(self);
        Object ready = queue.pollFirst();
        if (ready != null) {
            return ready;
        }
        return environment.yieldAndRun(() -> {
            try {
                if (timeoutSeconds == null) {
                    return queue.takeFirst();
                }
                long millis = ((BDecimal) timeoutSeconds).decimalValue().multiply(MILLIS_PER_SECOND)
                        .setScale(0, RoundingMode.CEILING).longValue();
                return queue.pollFirst(millis, TimeUnit.MILLISECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return ErrorCreator.createError(StringUtils.fromString(
                        "interrupted while waiting for the next task event"));
            }
        });
    }

    @SuppressWarnings("unchecked")
    private static LinkedBlockingDeque<Object> queue(BObject self) {
        return (LinkedBlockingDeque<Object>) self.getNativeData(QUEUE);
    }
}
