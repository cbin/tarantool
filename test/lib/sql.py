import sql_ast
import re

object_no_re = re.compile("[a-z_]*", re.I)


# Begin -- grammar generated by Yapps
import sys, re
from yapps import runtime

class sqlScanner(runtime.Scanner):
    patterns = [
        ("','", re.compile(',')),
        ("'\\)'", re.compile('\\)')),
        ('","', re.compile(',')),
        ("'\\('", re.compile('\\(')),
        ("'='", re.compile('=')),
        ("'\\*'", re.compile('\\*')),
        ('\\s+', re.compile('\\s+')),
        ('NUM', re.compile('[+-]?[0-9]+')),
        ('ID', re.compile('[a-z_]+[0-9]+')),
        ('PROC_ID', re.compile('[a-z_][a-z0-9_.]*')),
        ('STR', re.compile("'([^']+|\\\\.)*'")),
        ('PING', re.compile('ping')),
        ('INSERT', re.compile('insert')),
        ('UPDATE', re.compile('update')),
        ('DELETE', re.compile('delete')),
        ('SELECT', re.compile('select')),
        ('INTO', re.compile('into')),
        ('FROM', re.compile('from')),
        ('WHERE', re.compile('where')),
        ('VALUES', re.compile('values')),
        ('SET', re.compile('set')),
        ('OR', re.compile('or')),
        ('LIMIT', re.compile('limit')),
        ('CALL', re.compile('call')),
        ('END', re.compile('\\s*$')),
    ]
    def __init__(self, str,*args,**kw):
        runtime.Scanner.__init__(self,None,{'\\s+':None,},str,*args,**kw)

class sql(runtime.Parser):
    Context = runtime.Context
    def sql(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'sql', [])
        _token = self._peek('INSERT', 'UPDATE', 'DELETE', 'SELECT', 'CALL', 'PING', context=_context)
        if _token == 'INSERT':
            insert = self.insert(_context)
            stmt = insert
        elif _token == 'UPDATE':
            update = self.update(_context)
            stmt = update
        elif _token == 'DELETE':
            delete = self.delete(_context)
            stmt = delete
        elif _token == 'SELECT':
            select = self.select(_context)
            stmt = select
        elif _token == 'CALL':
            call = self.call(_context)
            stmt = call
        else: # == 'PING'
            ping = self.ping(_context)
            stmt = ping
        END = self._scan('END', context=_context)
        return stmt

    def insert(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'insert', [])
        INSERT = self._scan('INSERT', context=_context)
        if self._peek('INTO', 'ID', context=_context) == 'INTO':
            INTO = self._scan('INTO', context=_context)
        ident = self.ident(_context)
        VALUES = self._scan('VALUES', context=_context)
        value_list = self.value_list(_context)
        return sql_ast.StatementInsert(ident, value_list)

    def update(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'update', [])
        UPDATE = self._scan('UPDATE', context=_context)
        ident = self.ident(_context)
        SET = self._scan('SET', context=_context)
        update_list = self.update_list(_context)
        opt_simple_where = self.opt_simple_where(_context)
        return sql_ast.StatementUpdate(ident, update_list, opt_simple_where)

    def delete(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'delete', [])
        DELETE = self._scan('DELETE', context=_context)
        FROM = self._scan('FROM', context=_context)
        ident = self.ident(_context)
        opt_simple_where = self.opt_simple_where(_context)
        return sql_ast.StatementDelete(ident, opt_simple_where)

    def select(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'select', [])
        SELECT = self._scan('SELECT', context=_context)
        self._scan("'\\*'", context=_context)
        FROM = self._scan('FROM', context=_context)
        ident = self.ident(_context)
        opt_where = self.opt_where(_context)
        opt_limit = self.opt_limit(_context)
        return sql_ast.StatementSelect(ident, opt_where, opt_limit)

    def ping(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'ping', [])
        PING = self._scan('PING', context=_context)
        return sql_ast.StatementPing()

    def call(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'call', [])
        CALL = self._scan('CALL', context=_context)
        PROC_ID = self._scan('PROC_ID', context=_context)
        value_list = self.value_list(_context)
        return sql_ast.StatementCall(PROC_ID, value_list)

    def predicate(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'predicate', [])
        ident = self.ident(_context)
        self._scan("'='", context=_context)
        constant = self.constant(_context)
        return (ident, constant)

    def opt_simple_where(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'opt_simple_where', [])
        _token = self._peek('WHERE', 'END', context=_context)
        if _token == 'END':
            return None
        else: # == 'WHERE'
            WHERE = self._scan('WHERE', context=_context)
            predicate = self.predicate(_context)
            return predicate

    def opt_where(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'opt_where', [])
        _token = self._peek('WHERE', 'LIMIT', 'END', context=_context)
        if _token != 'WHERE':
            return None
        else: # == 'WHERE'
            WHERE = self._scan('WHERE', context=_context)
            disjunction = self.disjunction(_context)
            return disjunction

    def disjunction(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'disjunction', [])
        predicate = self.predicate(_context)
        disjunction = [predicate]
        if self._peek('OR', 'LIMIT', 'END', context=_context) == 'OR':
            while 1:
                OR = self._scan('OR', context=_context)
                predicate = self.predicate(_context)
                disjunction.append(predicate)
                if self._peek('OR', 'LIMIT', 'END', context=_context) != 'OR': break
        return disjunction

    def opt_limit(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'opt_limit', [])
        _token = self._peek('LIMIT', 'END', context=_context)
        if _token == 'END':
            return 0xffffffff
        else: # == 'LIMIT'
            LIMIT = self._scan('LIMIT', context=_context)
            NUM = self._scan('NUM', context=_context)
            return int(NUM)

    def value_list(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'value_list', [])
        self._scan("'\\('", context=_context)
        value_list = []
        if self._peek("'\\)'", '","', 'NUM', 'STR', context=_context) in ['NUM', 'STR']:
            expr = self.expr(_context)
            value_list = [expr]
            if self._peek('","', "'\\)'", context=_context) == '","':
                while 1:
                    self._scan('","', context=_context)
                    expr = self.expr(_context)
                    value_list.append(expr)
                    if self._peek('","', "'\\)'", context=_context) != '","': break
        self._scan("'\\)'", context=_context)
        return value_list

    def update_list(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'update_list', [])
        predicate = self.predicate(_context)
        update_list = [predicate]
        if self._peek("','", 'WHERE', 'END', context=_context) == "','":
            while 1:
                self._scan("','", context=_context)
                predicate = self.predicate(_context)
                update_list.append(predicate)
                if self._peek("','", 'WHERE', 'END', context=_context) != "','": break
        return update_list

    def expr(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'expr', [])
        constant = self.constant(_context)
        return constant

    def constant(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'constant', [])
        _token = self._peek('NUM', 'STR', context=_context)
        if _token == 'NUM':
            NUM = self._scan('NUM', context=_context)
            return int(NUM)
        else: # == 'STR'
            STR = self._scan('STR', context=_context)
            return STR[1:-1]

    def ident(self, _parent=None):
        _context = self.Context(_parent, self._scanner, 'ident', [])
        ID = self._scan('ID', context=_context)
        return int(object_no_re.sub("", ID))


def parse(rule, text):
    P = sql(sqlScanner(text))
    return runtime.wrap_error_reporter(P, rule)

# End -- grammar generated by Yapps



# SQL is case-insensitive, but in yapps it's not possible to
# specify that a token must match in case-insensitive fashion.
# This is hack to add re.IGNORECASE flag to all regular
# expressions that represent tokens in the generated grammar.

sqlScanner.patterns = map(lambda tup:
                          (tup[0], re.compile(tup[1].pattern, re.IGNORECASE)),
                          sqlScanner.patterns)

# vim: nospell syntax=off ts=4 et

