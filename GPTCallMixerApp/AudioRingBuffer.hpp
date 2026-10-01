#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

// Single-producer/single-consumer stereo Float32 ring buffer. Each source uses
// a separate ring for every destination, so no consumer cursor is shared.
class AudioRingBuffer {
public:
    explicit AudioRingBuffer(std::size_t capacityFrames = 32768)
        : capacity_(nextPowerOfTwo(capacityFrames)),
          mask_(capacity_ - 1),
          samples_(capacity_ * 2, 0.0f) {}

    void reset() noexcept {
        readFrame_.store(0, std::memory_order_release);
        writeFrame_.store(0, std::memory_order_release);
        underruns_.store(0, std::memory_order_relaxed);
        overruns_.store(0, std::memory_order_relaxed);
    }

    void writeInterleaved(const float* source, std::size_t frames, std::size_t channels) noexcept {
        if (source == nullptr || frames == 0 || channels == 0) return;

        auto write = writeFrame_.load(std::memory_order_relaxed);
        const auto read = readFrame_.load(std::memory_order_acquire);
        if (frames > capacity_) {
            source += (frames - capacity_) * channels;
            frames = capacity_;
            overruns_.fetch_add(1, std::memory_order_relaxed);
        }
        const auto used = write - read;
        const auto freeFrames = used < capacity_ ? capacity_ - used : 0;
        if (frames > freeFrames) {
            frames = static_cast<std::size_t>(freeFrames);
            overruns_.fetch_add(1, std::memory_order_relaxed);
        }
        if (frames == 0) return;

        for (std::size_t frame = 0; frame < frames; ++frame) {
            const auto index = ((write + frame) & mask_) * 2;
            const float left = source[frame * channels];
            const float right = channels > 1 ? source[frame * channels + 1] : left;
            samples_[index] = left;
            samples_[index + 1] = right;
        }
        writeFrame_.store(write + frames, std::memory_order_release);
    }

    void writePlanar(
        const float* left,
        const float* right,
        std::size_t frames
    ) noexcept {
        if (left == nullptr || frames == 0) return;

        auto write = writeFrame_.load(std::memory_order_relaxed);
        const auto read = readFrame_.load(std::memory_order_acquire);
        if (frames > capacity_) {
            const auto skip = frames - capacity_;
            left += skip;
            if (right != nullptr) right += skip;
            frames = capacity_;
            overruns_.fetch_add(1, std::memory_order_relaxed);
        }
        const auto used = write - read;
        const auto freeFrames = used < capacity_ ? capacity_ - used : 0;
        if (frames > freeFrames) {
            frames = static_cast<std::size_t>(freeFrames);
            overruns_.fetch_add(1, std::memory_order_relaxed);
        }
        if (frames == 0) return;

        for (std::size_t frame = 0; frame < frames; ++frame) {
            const auto index = ((write + frame) & mask_) * 2;
            samples_[index] = left[frame];
            samples_[index + 1] = right != nullptr ? right[frame] : left[frame];
        }
        writeFrame_.store(write + frames, std::memory_order_release);
    }

    // Adds available audio to an interleaved stereo mix buffer. Old excess
    // frames are discarded to keep latency bounded after a stalled consumer.
    std::size_t addToInterleaved(
        float* destination,
        std::size_t requestedFrames,
        float gain = 1.0f,
        std::size_t targetQueuedFrames = 512
    ) noexcept {
        if (destination == nullptr || requestedFrames == 0) return 0;

        auto read = readFrame_.load(std::memory_order_relaxed);
        const auto write = writeFrame_.load(std::memory_order_acquire);
        auto available = write - read;
        if (available > requestedFrames + targetQueuedFrames) {
            const auto skip = available - requestedFrames - targetQueuedFrames;
            read += skip;
            available -= skip;
        }
        const auto count = std::min<std::uint64_t>(available, requestedFrames);
        for (std::size_t frame = 0; frame < count; ++frame) {
            const auto index = ((read + frame) & mask_) * 2;
            destination[frame * 2] += samples_[index] * gain;
            destination[frame * 2 + 1] += samples_[index + 1] * gain;
        }
        readFrame_.store(read + count, std::memory_order_release);
        if (count < requestedFrames) {
            underruns_.fetch_add(1, std::memory_order_relaxed);
        }
        return static_cast<std::size_t>(count);
    }

    std::uint64_t underruns() const noexcept { return underruns_.load(std::memory_order_relaxed); }
    std::uint64_t overruns() const noexcept { return overruns_.load(std::memory_order_relaxed); }

private:
    static std::size_t nextPowerOfTwo(std::size_t value) noexcept {
        std::size_t result = 1;
        while (result < value) result <<= 1;
        return result;
    }

    const std::size_t capacity_;
    const std::size_t mask_;
    std::vector<float> samples_;
    std::atomic<std::uint64_t> readFrame_{0};
    std::atomic<std::uint64_t> writeFrame_{0};
    std::atomic<std::uint64_t> underruns_{0};
    std::atomic<std::uint64_t> overruns_{0};
};
