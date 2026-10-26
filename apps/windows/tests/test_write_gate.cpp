#include "opensvn/write_gate.hpp"

#include "opensvn/errors.hpp"
#include "test_support.hpp"

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <thread>

namespace opensvn {
namespace {

TEST(WorkingCopyLocator, FindsTheNearestDotSvnDirectory) {
    test::TempDir temp;
    std::filesystem::create_directories(temp.path() / ".svn");
    std::filesystem::create_directories(temp.path() / "src" / "nested");
    test::write_text(temp.path() / "src" / "nested" / "file.txt", "x");

    const auto root = WorkingCopyLocator::root(temp.path() / "src" / "nested" / "file.txt");
    ASSERT_TRUE(root.has_value());
    EXPECT_EQ(std::filesystem::weakly_canonical(*root),
              std::filesystem::weakly_canonical(temp.path()));
    EXPECT_TRUE(WorkingCopyLocator::is_working_copy(temp.path() / "src"));
}

TEST(WorkingCopyLocator, RejectsPlainDirectories) {
    test::TempDir temp;
    std::filesystem::create_directories(temp.path() / "src");
    EXPECT_FALSE(WorkingCopyLocator::root(temp.path() / "src").has_value());
    EXPECT_FALSE(WorkingCopyLocator::is_working_copy(temp.path()));
}

TEST(WriteGate, SerialisesWritesOnTheSameWorkingCopy) {
    WCWriteGate gate(4);
    std::atomic<int> active{0};
    std::atomic<int> maximum{0};
    std::atomic<int> completed{0};

    const auto work = [&] {
        gate.with_lock("wc-a", [&] {
            const int current = ++active;
            int expected = maximum.load();
            while (current > expected && !maximum.compare_exchange_weak(expected, current)) {
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            --active;
            ++completed;
        });
    };

    std::thread first(work);
    std::thread second(work);
    first.join();
    second.join();

    EXPECT_EQ(completed.load(), 2);
    EXPECT_EQ(maximum.load(), 1);
}

TEST(WriteGate, AllowsDifferentWorkingCopiesToOverlap) {
    WCWriteGate gate(2);
    std::atomic<int> active{0};
    std::atomic<int> maximum{0};

    const auto work = [&](const char* key) {
        gate.with_lock(key, [&] {
            const int current = ++active;
            int expected = maximum.load();
            while (current > expected && !maximum.compare_exchange_weak(expected, current)) {
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(120));
            --active;
        });
    };

    std::thread first(work, "wc-a");
    std::thread second(work, "wc-b");
    first.join();
    second.join();
    EXPECT_EQ(maximum.load(), 2);
}

TEST(WriteGate, WaitingForAWorkingCopyCanBeCancelled) {
    WCWriteGate gate(1);
    gate.acquire("wc-busy");

    std::stop_source stop;
    std::atomic<bool> started{false};
    std::atomic<bool> cancelled{false};
    std::thread waiter([&] {
        started.store(true);
        try {
            gate.acquire("wc-busy", stop.get_token());
        } catch (const SVNException& error) {
            cancelled.store(error.error().code == SVNErrorCode::cancelled);
        }
    });

    while (!started.load()) std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    stop.request_stop();
    waiter.join();

    EXPECT_TRUE(cancelled.load());
    EXPECT_EQ(gate.active_count(), 1);
    gate.release("wc-busy");
    EXPECT_EQ(gate.active_count(), 0);
}

TEST(WriteGate, SerialisesAcrossGateInstances) {
    // Two instances stand in for two OpenSVN processes.
    WCWriteGate first(4);
    WCWriteGate second(4);
    first.acquire("cross-instance");

    std::atomic<bool> attempted{false};
    std::atomic<bool> acquired{false};
    std::thread waiter([&] {
        attempted.store(true);
        second.acquire("cross-instance");
        acquired.store(true);
        second.release("cross-instance");
    });

    while (!attempted.load()) std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    EXPECT_FALSE(acquired.load());

    first.release("cross-instance");
    waiter.join();
    EXPECT_TRUE(acquired.load());
}

TEST(WriteGate, ClampsTheConcurrencyLimit) {
    WCWriteGate gate(0);
    EXPECT_EQ(gate.max_concurrent_writes(), WCWriteGate::minimum_concurrent);
    gate.set_max_concurrent(1000);
    EXPECT_EQ(gate.max_concurrent_writes(), WCWriteGate::maximum_concurrent);

    gate.acquire("wc");
    EXPECT_TRUE(gate.is_busy("wc"));
    EXPECT_EQ(gate.active_count(), 1);
    gate.release("wc");
    EXPECT_FALSE(gate.is_busy("wc"));
    EXPECT_EQ(gate.active_count(), 0);
}

} // namespace
} // namespace opensvn
