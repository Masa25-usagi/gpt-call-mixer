#include "../GPTCallMixerApp/AudioRingBuffer.hpp"

#include <cassert>
#include <atomic>
#include <cmath>
#include <iostream>
#include <thread>

static bool closeEnough(float left, float right) {
    return std::fabs(left - right) < 0.0001f;
}

int main() {
    {
        AudioRingBuffer ring(16);
        const float mono[] = {0.25f, -0.5f, 0.75f};
        ring.writeInterleaved(mono, 3, 1);
        float output[6] = {};
        assert(ring.addToInterleaved(output, 3) == 3);
        assert(closeEnough(output[0], 0.25f) && closeEnough(output[1], 0.25f));
        assert(closeEnough(output[2], -0.5f) && closeEnough(output[3], -0.5f));
        assert(closeEnough(output[4], 0.75f) && closeEnough(output[5], 0.75f));
    }

    {
        AudioRingBuffer first(16);
        AudioRingBuffer second(16);
        const float a[] = {0.2f, 0.3f, 0.4f, 0.5f};
        const float b[] = {0.1f, -0.1f, -0.2f, 0.2f};
        first.writeInterleaved(a, 2, 2);
        second.writeInterleaved(b, 2, 2);
        float mix[4] = {};
        first.addToInterleaved(mix, 2);
        second.addToInterleaved(mix, 2);
        assert(closeEnough(mix[0], 0.3f));
        assert(closeEnough(mix[1], 0.2f));
        assert(closeEnough(mix[2], 0.2f));
        assert(closeEnough(mix[3], 0.7f));
    }

    {
        AudioRingBuffer ring(4);
        const float samples[] = {
            0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5
        };
        ring.writeInterleaved(samples, 6, 2);
        float output[8] = {};
        assert(ring.addToInterleaved(output, 4) == 4);
        assert(closeEnough(output[0], 2.0f));
        assert(closeEnough(output[6], 5.0f));
        assert(ring.overruns() == 1);
    }

    {
        AudioRingBuffer ring(64);
        std::atomic<bool> producerDone{false};
        std::atomic<bool> invalidSequence{false};
        std::atomic<std::uint64_t> observedFrames{0};

        std::thread producer([&] {
            for (std::uint64_t frame = 1; frame <= 200000; ++frame) {
                const float sample[] = {
                    static_cast<float>(frame), static_cast<float>(frame)
                };
                ring.writeInterleaved(sample, 1, 2);
            }
            producerDone.store(true, std::memory_order_release);
        });

        std::thread consumer([&] {
            float previous = 0.0f;
            unsigned emptyReadsAfterDone = 0;
            while (!producerDone.load(std::memory_order_acquire)
                || emptyReadsAfterDone < 100) {
                float output[2] = {};
                if (ring.addToInterleaved(output, 1, 1.0f, 64) == 1) {
                    if (!closeEnough(output[0], output[1]) || output[0] <= previous) {
                        invalidSequence.store(true, std::memory_order_relaxed);
                    }
                    previous = output[0];
                    observedFrames.fetch_add(1, std::memory_order_relaxed);
                    emptyReadsAfterDone = 0;
                } else if (producerDone.load(std::memory_order_acquire)) {
                    ++emptyReadsAfterDone;
                }
            }
        });

        producer.join();
        consumer.join();
        assert(!invalidSequence.load(std::memory_order_relaxed));
        assert(observedFrames.load(std::memory_order_relaxed) > 0);
        assert(ring.overruns() > 0);
    }

    std::cout << "AudioRingBufferTests: PASS\n";
    return 0;
}
