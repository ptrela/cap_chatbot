FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --without development test

COPY . .

EXPOSE 3000

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
