threads_count = ENV.fetch("PUMA_THREADS", 5).to_i
threads threads_count, threads_count

workers ENV.fetch("WEB_CONCURRENCY", 2).to_i

bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 3000)}"

preload_app!
