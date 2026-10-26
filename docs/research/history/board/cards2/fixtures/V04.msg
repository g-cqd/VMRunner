Prove the control listener closes every connection it accepts and leaves no descriptor open

Seven paths each end with the client reading the end of file: a normal call then the client closing, a client of another user, a client past the connection limit, a request longer than the limit, a silent client, a connection out of requests, and a connection open when the listener stops. A run of mixed connections over real listeners then compares the descriptor count before and after.

