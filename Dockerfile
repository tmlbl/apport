FROM ubuntu:latest

# RUN apt-get update && apt-get install -y build-essential
#
RUN echo "hello" > foo.txt

RUN cp foo.txt bar.txt
